import MetricKit

/// Subscribes to MetricKit for native crash and performance diagnostics
/// (launch time, hangs, memory, battery, and full crash reports with
/// symbolicated stack traces) — no custom crash-reporting code needed.
/// Call `DiagnosticsReporter.shared.start()` once at app launch.
@MainActor
public final class DiagnosticsReporter: NSObject {
    public static let shared = DiagnosticsReporter()

    private override init() { super.init() }

    public func start() {
        MXMetricManager.shared.add(self)
    }
}

extension DiagnosticsReporter: MXMetricManagerSubscriber {
    public nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            Log.security.info("MetricKit metric payload for period ending \(payload.timeStampEnd, privacy: .public)")
        }
    }

    public nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            if let crashes = payload.crashDiagnostics {
                for crash in crashes {
                    let reason = crash.terminationReason ?? "unknown reason"
                    Log.security.fault("MetricKit crash diagnostic: \(reason, privacy: .public)")
                }
            }
            if let hangs = payload.hangDiagnostics {
                for hang in hangs {
                    Log.security.error("MetricKit hang diagnostic, duration: \(hang.hangDuration.description, privacy: .public)")
                }
            }
        }
    }
}
