import Foundation
import MetricKit

/// Receives the daily MetricKit payloads (energy, CPU, hangs, crashes) and
/// writes them to the unified log so they can be collected with `log show`.
final class MetricsSubscriber: NSObject, MXMetricManagerSubscriber {
    func start() {
        MXMetricManager.shared.add(self)
    }

    func stop() {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let json = String(data: payload.jsonRepresentation(), encoding: .utf8) ?? ""
            Log.metrics.notice("MetricKit metric payload: \(json, privacy: .public)")
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let json = String(data: payload.jsonRepresentation(), encoding: .utf8) ?? ""
            Log.metrics.notice("MetricKit diagnostic payload: \(json, privacy: .public)")
        }
    }
}
