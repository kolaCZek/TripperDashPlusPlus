//
//  CrashDiagnostics.swift
//  TripperDashPP
//
//  ⚠️ DIAGNOSTIC BRANCH ONLY (`diag/connection-logging`) — NOT FOR MERGE.
//
//  MetricKit subscriber. `ConnDiag`'s lifecycle lines (launch / scenePhase /
//  memoryWarning) can show the shape of a resource-pressure kill but can't
//  prove it, because the app never gets a chance to run code once jetsam
//  actually terminates it. MetricKit closes that gap: iOS itself keeps a
//  record of *why* the process last went away and hands it to the app on a
//  LATER launch (delivery is opportunistic — typically within 24h, once a
//  day, sometimes on next launch — never synchronous with the kill).
//
//  Two payload types matter here:
//  - `MXCrashDiagnostic` — an actual crash (signal/exception) with a
//    symbolicatable stack trace. If the disconnect was a real crash (not a
//    jetsam kill), this is the smoking gun.
//  - `MXMetricPayload.applicationExitMetrics` — aggregate exit-reason
//    counters since the last report: `foregroundExitData` /
//    `backgroundExitData`, each breaking down into
//    `memoryResourceLimitExitCount`, `cpuResourceLimitExitCount`,
//    `appWatchdogExitCount`, `badAccessExitCount`, `abnormalExitCount`,
//    `normalAppExitCount`, etc. THIS is what can finally confirm or rule
//    out "iOS killed the app for using too much memory/CPU in the
//    background" instead of us inferring it from a signal-shaped hole in
//    the connection log.
//
//  Both get written into the SAME ConnDiag log/category so a field-test
//  share captures the full picture in one file. MetricKit reports are
//  low-frequency (not per-launch) — don't expect a line on every run.
//
//  Remove this file (and the MXMetricManager subscribe call) before the
//  feature work is merged — this whole branch is a throwaway diagnostic aid.
//

import Foundation
import MetricKit

final class CrashDiagnosticsSubscriber: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashDiagnosticsSubscriber()

    /// Call once at app launch (from `TripperDashPPApp.init`). Idempotent —
    /// MetricKit itself no-ops a duplicate `add` of the same subscriber.
    func start() {
        MXMetricManager.shared.add(self)
        ConnDiag.log("crashdiag", "MetricKit subscriber registered")
    }

    // MARK: - MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exit = payload.applicationExitMetrics else { continue }
            let period = "\(payload.timeStampBegin.formatted()) → \(payload.timeStampEnd.formatted())"

            let fg = exit.foregroundExitData
            ConnDiag.log("crashdiag",
                "MetricKit exit report [\(period)] FOREGROUND: " +
                "normal=\(fg.cumulativeNormalAppExitCount) " +
                "memoryResourceLimit=\(fg.cumulativeMemoryResourceLimitExitCount) " +
                "badAccess=\(fg.cumulativeBadAccessExitCount) " +
                "abnormal=\(fg.cumulativeAbnormalExitCount) " +
                "appWatchdog=\(fg.cumulativeAppWatchdogExitCount)")

            let bg = exit.backgroundExitData
            ConnDiag.log("crashdiag",
                "MetricKit exit report [\(period)] BACKGROUND: " +
                "normal=\(bg.cumulativeNormalAppExitCount) " +
                "memoryResourceLimit=\(bg.cumulativeMemoryResourceLimitExitCount) " +
                "cpuResourceLimit=\(bg.cumulativeCPUResourceLimitExitCount) " +
                "memoryPressure=\(bg.cumulativeMemoryPressureExitCount) " +
                "badAccess=\(bg.cumulativeBadAccessExitCount) " +
                "abnormal=\(bg.cumulativeAbnormalExitCount) " +
                "appWatchdog=\(bg.cumulativeAppWatchdogExitCount) " +
                "suspendedWithLocked=\(bg.cumulativeSuspendedWithLockedFileExitCount) " +
                "background=\(bg.cumulativeBackgroundTaskAssertionTimeoutExitCount)")

            // This is the line that actually answers "was it jetsam?": any
            // nonzero background memoryResourceLimit/memoryPressure count in
            // the window that overlaps a reported ride disconnect confirms
            // it; all-zero across a window that DID have a disconnect rules
            // it out and points back at the network/socket path instead.
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let period = "\(payload.timeStampBegin.formatted()) → \(payload.timeStampEnd.formatted())"
            if let crashes = payload.crashDiagnostics, !crashes.isEmpty {
                for crash in crashes {
                    let reason = crash.exceptionType.map(String.init(describing:)) ?? "?"
                    let code = crash.exceptionCode.map(String.init(describing:)) ?? "?"
                    let signal = crash.signal.map(String.init(describing:)) ?? "?"
                    ConnDiag.log("crashdiag",
                        "⚠️ MetricKit CRASH [\(period)] type=\(reason) code=\(code) signal=\(signal) " +
                        "termination=\(crash.terminationReason ?? "?") " +
                        "virtualMemRegionInfo=\(crash.virtualMemoryRegionInfo ?? "?")")
                    // The line above tells us THAT it crashed and roughly how
                    // (e.g. type=6/signal=5 = EXC_BREAKPOINT/SIGTRAP, the
                    // classic Swift runtime-trap signature — force-unwrap of
                    // nil, fatalError/precondition, array out-of-bounds,
                    // trapping integer overflow, `try!` — as opposed to
                    // type=1 EXC_BAD_ACCESS which would be memory corruption
                    // or jetsam-adjacent). It does NOT tell us WHERE. Log the
                    // call stack tree's raw JSON too so a real crash can
                    // actually be pinpointed to a file/line via `atos`
                    // instead of us guessing from context. Frame addresses
                    // are unsymbolicated offsets (need the matching dSYM +
                    // `atos -arch arm64 -o <dSYM> -l 0x1 <hex offset>` per
                    // Apple's documented process) — raw but far better than
                    // nothing.
                    if let json = String(data: crash.callStackTree.jsonRepresentation(), encoding: .utf8) {
                        ConnDiag.log("crashdiag", "CRASH call stack tree (raw, unsymbolicated): \(json)")
                    }
                }
            }
            if let hangs = payload.hangDiagnostics, !hangs.isEmpty {
                ConnDiag.log("crashdiag", "MetricKit reported \(hangs.count) hang diagnostic(s) in [\(period)]")
            }
        }
    }
}
