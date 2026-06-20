//
//  DashSocket.swift
//  TripperDashPP
//
//  UDP transport to the Tripper dash. Wraps a BSD POSIX socket so we
//  have full control over local bind, remote destination, and the
//  asymmetric (TX→:2000, RX←:2002) flow the K1G protocol needs.
//
//  Why BSD sockets and not NWConnection?
//
//  An earlier revision used `NWConnection(to: 192.168.1.1:2002)` — but
//  Apple's `NWConnection` on UDP behaves as a "connected" peer: it
//  filters inbound datagrams by the peer endpoint set at construction
//  time. The Tripper dash sends its initial burst to the phone from
//  port 2002 (not the same port we send to), so `NWConnection`
//  silently dropped every reply (rx=0 in the BikeLink log) and also
//  surfaced `nw_endpoint_flow_failed_with_error … unsatisfied (No
//  network route)` on the dry-run flow that tried to reach :2000.
//
//  The canonical Python equivalent of this design is
//  `better-dash/tripper_app_like_nav.py:`
//   - `open_broadcast_socket(bind_ip, 2000)`     # TX, bound to :2000
//   - `open_listen_socket_2002(bind_ip, 2002)`   # RX, bound to :2002
//
//  We collapse both into a single `DashSocket`: one POSIX fd, bound
//  to `localPort` (rxPort=2002), `sendto` going to `host:port`
//  (bikeIPv4:txPort=2000). A `DispatchSourceRead` pulls inbound
//  datagrams off the kernel and pushes them through an
//  `AsyncStream<Data>` for the rest of the app to consume.
//
//  We keep the public API (`init(host:port:localPort:)`,
//  `start(timeout:)`, `send(_:)`, `cancel()`, `inbound`) identical to
//  the old NWConnection implementation so callers don't have to change.
//

import Foundation
import Darwin
import os

actor DashSocket {

    // MARK: - Public API

    enum State: Sendable, Equatable {
        case setup
        case waiting(String)     // human-readable reason
        case ready
        case failed(String)
        case cancelled
    }

    /// Inbound packets — payload only, no addressing.
    nonisolated let inbound: AsyncStream<Data>

    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let host: String
    private let port: UInt16
    private let localPort: UInt16
    private var fd: Int32 = -1
    private var dest = sockaddr_in()
    private var readSource: DispatchSourceRead?
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "DashSocket")
    private var state: State = .setup
    /// Total datagrams received since socket creation. Logged at first-RX
    /// (info level) and at cancel, so timeouts can be diagnosed without
    /// digging through debug spam.
    private var rxDatagramCount: UInt64 = 0
    /// IO queue for the DispatchSourceRead handler and any blocking
    /// `sendto` calls. Off-main, isolated per socket instance.
    private let ioQueue: DispatchQueue

    // MARK: - Init

    /// Create a UDP socket targeting `host:remotePort`, bound to
    /// `localPort`.
    ///
    /// - Parameter localPort: REQUIRED local-bind port. The real dash
    ///   sends its modulus/exponent from its own fixed port (2002), not
    ///   to the ephemeral source port of our outbound packets, so we
    ///   MUST bind locally to receive those replies. Pass `K1G.rxPort`
    ///   unless you really know what you're doing.
    init(host: String, port: UInt16, localPort: UInt16) {
        self.host = host
        self.port = port
        self.localPort = localPort
        self.ioQueue = DispatchQueue(label: "DashSocket.io.\(localPort)", qos: .userInitiated)

        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream(bufferingPolicy: .unbounded) { c in cont = c }
        self.inboundContinuation = cont
    }

    // MARK: - Lifecycle

    /// Create the BSD socket, bind to `localPort`, configure the
    /// destination address. Returns synchronously on success — UDP has
    /// no "ready" handshake. `timeout` is kept for API compatibility
    /// with the previous NWConnection-based implementation but is
    /// effectively unused for BSD sockets.
    func start(timeout: TimeInterval = 5.0) async throws {
        guard fd < 0 else {
            log.notice("DashSocket.start called twice; ignoring")
            return
        }

        // 1) Create UDP socket.
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        if s < 0 {
            let err = errnoString()
            log.error("socket() failed: \(err, privacy: .public)")
            throw makeError(-1, "socket(): \(err)")
        }

        // 2) SO_REUSEADDR so reconnects after a crash don't hit EADDRINUSE.
        var on: Int32 = 1
        if setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size)) < 0 {
            let err = errnoString()
            log.notice("SO_REUSEADDR failed (non-fatal): \(err, privacy: .public)")
        }
        // SO_REUSEPORT belt-and-braces; ignore failures.
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))

        // 3) Bind to 0.0.0.0:localPort. We can't bind to a specific
        //    interface IP without knowing the phone's address on the
        //    bike's AP, and ANY works fine because the bike's network
        //    is the only one that routes 192.168.1.x.
        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_addr.s_addr = INADDR_ANY.bigEndian   // 0.0.0.0
        bindAddr.sin_port = localPort.bigEndian
        let bindResult = withUnsafePointer(to: &bindAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            let err = errnoString()
            close(s)
            log.error("bind(0.0.0.0:\(self.localPort)) failed: \(err, privacy: .public)")
            throw makeError(-2, "bind(0.0.0.0:\(localPort)): \(err)")
        }

        // 4) Resolve+stash the destination sockaddr for sendto().
        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &destAddr.sin_addr) != 1 {
            let err = errnoString()
            close(s)
            log.error("inet_pton(\(self.host, privacy: .public)) failed: \(err, privacy: .public)")
            throw makeError(-3, "inet_pton(\(host)): \(err)")
        }
        self.dest = destAddr

        // 5) Non-blocking so sendto/recv don't ever wedge the io queue.
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        // 6) Pre-arm a DispatchSourceRead. It fires on the io queue
        //    whenever the kernel has at least one datagram queued.
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: ioQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            // Drain ALL pending datagrams in one shot — DispatchSourceRead
            // only fires on the level-triggered edge, and you can have
            // multiple datagrams queued from a single edge.
            self.drainAllPending()
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            // Close the fd on cancel; capture by value so the actor
            // doesn't need to be touched here.
            let toClose = s
            close(toClose)
            Task { await self.didCancel() }
        }
        src.resume()

        self.fd = s
        self.readSource = src
        self.state = .ready
        log.info("DashSocket ready (POSIX fd=\(s), bound :\(self.localPort), dest \(self.host, privacy: .public):\(self.port))")
    }

    /// Send a single UDP datagram to the dash.
    func send(_ data: Data) async throws {
        guard fd >= 0 else {
            throw makeError(-4, "send() before start() or after cancel()")
        }
        let fdCopy = fd
        var destCopy = dest
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ioQueue.async {
                let sent: ssize_t = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ssize_t in
                    guard let base = raw.baseAddress else { return -1 }
                    return withUnsafePointer(to: &destCopy) { ptr -> ssize_t in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fdCopy, base, data.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
                if sent < 0 {
                    let err = String(cString: strerror(errno))
                    cont.resume(throwing: NSError(
                        domain: "DashSocket",
                        code: Int(errno),
                        userInfo: [NSLocalizedDescriptionKey: "sendto(): \(err)"]
                    ))
                } else if sent != data.count {
                    cont.resume(throwing: NSError(
                        domain: "DashSocket",
                        code: -5,
                        userInfo: [NSLocalizedDescriptionKey: "sendto() short write: \(sent)/\(data.count) bytes"]
                    ))
                } else {
                    cont.resume()
                }
            }
        }
    }

    /// Tear the socket down.
    func cancel() {
        guard let src = readSource else { return }
        readSource = nil
        // The cancel handler closes the fd and updates state via didCancel().
        src.cancel()
    }

    // MARK: - Inbound drain

    /// Called from the io queue (DispatchSourceRead event handler).
    /// `nonisolated` so the dispatch handler can call it without an
    /// actor hop on the hot path.
    nonisolated private func drainAllPending() {
        // Trampoline into the actor to manipulate `fd` and counters.
        Task { await self.drainAllPendingOnActor() }
    }

    private func drainAllPendingOnActor() {
        guard fd >= 0 else { return }
        // Match real K1G frames + RTP-ish overhead. 2 KiB is well above
        // anything we expect on the control plane (largest is q3c.d at
        // ~150 B).
        var buf = [UInt8](repeating: 0, count: 2048)
        var fromAddr = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while true {
            let n: ssize_t = buf.withUnsafeMutableBufferPointer { bptr -> ssize_t in
                guard let base = bptr.baseAddress else { return -1 }
                return withUnsafeMutablePointer(to: &fromAddr) { ptr -> ssize_t in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, base, buf.count, 0, sa, &fromLen)
                    }
                }
            }
            if n > 0 {
                rxDatagramCount &+= 1
                let payload = Data(buf.prefix(Int(n)))
                if rxDatagramCount == 1 {
                    // First-RX log uses .info so it shows up at default level —
                    // critical for "did the dash respond at all?" diagnosis.
                    let srcIp = ipv4String(fromAddr.sin_addr)
                    let srcPort = UInt16(bigEndian: fromAddr.sin_port)
                    log.info("DashSocket first RX (\(n) B from \(srcIp, privacy: .public):\(srcPort))")
                }
                inboundContinuation.yield(payload)
                continue
            }
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    // No more data right now — exit drain, wait for the
                    // next DispatchSourceRead edge.
                    return
                }
                if errno == EINTR { continue }
                let err = String(cString: strerror(errno))
                log.error("UDP receive error: \(err, privacy: .public)")
                inboundContinuation.finish()
                return
            }
            // n == 0 — not meaningful for UDP, retry once.
            return
        }
    }

    private func didCancel() {
        fd = -1
        state = .cancelled
        log.info("DashSocket cancelled (rx=\(self.rxDatagramCount))")
        inboundContinuation.finish()
    }

    // MARK: - Helpers

    private func errnoString() -> String {
        String(cString: strerror(errno))
    }

    private func makeError(_ code: Int, _ msg: String) -> NSError {
        NSError(domain: "DashSocket", code: code,
                userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private nonisolated func ipv4String(_ a: in_addr) -> String {
        var addr = a
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        _ = inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
