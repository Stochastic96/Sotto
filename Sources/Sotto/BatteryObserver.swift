import Foundation
import IOKit.ps

// MARK: - BatteryObserver
//
// Checks battery state every 60 s via IOKit PowerSources (pure Swift, no polling CPU).
// Emits events at meaningful thresholds — does NOT spam on every percent change.
//
// Thresholds:
//   ≤ 15% (first cross) → .batteryLow(15) — "plug in soon"
//   ≤  5% (first cross) → .batteryLow(5)  — "critical, plug in NOW"
//   Plugged in          → .batteryCharging — silent (no HUD spam)

enum BatteryObserver {

    static func start() {
        Task.detached(priority: .background) { await watch() }
    }

    private static func watch() async {
        var alerted15 = false
        var alerted5  = false
        var lastCharging: Bool? = nil

        while true {
            if let state = readBattery() {
                // Charging state change (plugged in)
                if state.isCharging, lastCharging == false {
                    await EventBus.shared.emit(.batteryCharging(percent: state.percent))
                    alerted5 = false  // reset alerts when charging
                    alerted15 = false
                }
                lastCharging = state.isCharging

                // Only fire alerts when discharging
                if !state.isCharging {
                    if state.percent <= 5, !alerted5 {
                        alerted5 = true
                        await EventBus.shared.emit(.batteryLow(percent: state.percent))
                    } else if state.percent <= 15, !alerted15 {
                        alerted15 = true
                        await EventBus.shared.emit(.batteryLow(percent: state.percent))
                    }
                    // Reset if battery recovered (e.g. user plugged in briefly)
                    if state.percent > 20 { alerted15 = false; alerted5 = false }
                }
            }

            try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 s
        }
    }

    // MARK: - IOKit battery read (synchronous, cheap)

    struct BatteryState {
        let percent: Int
        let isCharging: Bool
    }

    static func readBattery() -> BatteryState? {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources  = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as [CFTypeRef]

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)
                    .takeUnretainedValue() as? [String: Any] else { continue }

            let current    = info[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max        = info[kIOPSMaxCapacityKey] as? Int ?? 100
            let powerState = info[kIOPSPowerSourceStateKey] as? String ?? ""
            let percent    = max > 0 ? Int(Double(current) / Double(max) * 100) : current
            let charging   = powerState == kIOPSACPowerValue

            return BatteryState(percent: percent, isCharging: charging)
        }
        return nil
    }
}
