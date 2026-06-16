//
//  DashSocket.swift
//  TripperDashPP
//
//  UDP transport to the Tripper dash. Wraps `NWConnection` so the rest
//  of the app talks in `Data` packets, not byte streams.
//
//  Two design choices worth flagging:
//
//   1) Bound to the **Wi-Fi** interface (`requiredInterfaceType = .wifi`),
//      not cellular or any. The bike's AP has no upstream internet; if we
//      let the OS fall through to LTE we'd silently spray our packets
//      into the void.
//
//   2) Single connection per (host, port). A separate `DashSocket` is
//      constructed for the RTP egress path in Phase 4.
//
//  Calls fan in through an `AsyncStream<Data>` so callers can `for await`
//  inbound packets.
//

import Foundation
import Network
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
    private let conn: NWConnection
    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp", category: "DashSocket")
    private var state: State = .setup

    // MARK: - Init

    /// Create a UDP socket targeting `host:port`. Bound to Wi-Fi.
    init(host: String, port: UInt16) {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(integerLiteral: port)
        )
        let params = NWParameters.udp
        params.requiredInterfaceType = .wifi
        params.prohibitExpensivePaths = true        // no LTE fallback
        params.prohibitConstrainedPaths = true      // no Low Data Mode

        self.conn = NWConnection(to: endpoint, using: params)

        var cont: AsyncStream<Data>.Continuation!
        self.inbound = AsyncStream { c in cont = c }
        self.inboundContinuation = cont
    }

    // MARK: - Lifecycle

    /// Start the connection and wait for `.ready` (or fail). Caller
    /// should `await` this before any `send(_:)`.
    func start(timeout: TimeInterval = 5.0) async throws {
        let queue = DispatchQueue(label: "DashSocket.\(UUID().uuidString.prefix(6))")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { [weak self] s in
                guard let self else { return }
                Task { await self.onStateChange(s, startContinuation: cont) }
            }
            conn.start(queue: queue)

            // Watchdog so a wedged connection doesn't hang the actor forever.
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                Task { await self.timeoutStart(cont: cont, after: timeout) }
            }
        }
        // Once .ready, kick off the inbound receive loop.
        receiveLoop()
    }

    /// Send a single UDP datagram.
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: err)
                } else {
                    cont.resume()
                }
            })
        }
    }

    /// Tear the connection down.
    func cancel() {
        conn.cancel()
        inboundContinuation.finish()
    }

    // MARK: - Inbound loop

    private func receiveLoop() {
        conn.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.inboundContinuation.yield(data)
            }
            if let error {
                self.log.error("UDP receive error: \(error.localizedDescription, privacy: .public)")
                self.inboundContinuation.finish()
                return
            }
            if isComplete {
                self.inboundContinuation.finish()
                return
            }
            // Re-arm.
            Task { await self.receiveLoop() }
        }
    }

    // MARK: - State handling

    private func onStateChange(_ s: NWConnection.State, startContinuation: CheckedContinuation<Void, Error>) {
        switch s {
        case .setup:
            state = .setup
        case .waiting(let err):
            state = .waiting(err.localizedDescription)
            log.notice("DashSocket waiting: \(err.localizedDescription, privacy: .public)")
        case .preparing:
            // No-op
            break
        case .ready:
            if state != .ready {
                state = .ready
                log.info("DashSocket ready")
                startContinuation.resume()
            }
        case .failed(let err):
            state = .failed(err.localizedDescription)
            log.error("DashSocket failed: \(err.localizedDescription, privacy: .public)")
            startContinuation.resume(throwing: err)
        case .cancelled:
            state = .cancelled
            inboundContinuation.finish()
        @unknown default:
            break
        }
    }

    private func timeoutStart(cont: CheckedContinuation<Void, Error>, after t: TimeInterval) {
        if state != .ready {
            log.error("DashSocket start timed out after \(t)s")
            conn.cancel()
            cont.resume(throwing: NSError(
                domain: "DashSocket",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for UDP socket to become ready"]
            ))
        }
    }
}
