import Foundation
import Network

enum NetworkObserver {
    // Written only from the NWPathMonitor callback (a single serial background
    // queue) and read from arbitrary callers — same pattern as the other *Observer
    // types in this codebase, just made explicit for Swift 6 strict concurrency.
    nonisolated(unsafe) private static var monitor: NWPathMonitor?
    nonisolated(unsafe) private static var isOnline = true

    static func start() {
        let monitor = NWPathMonitor()
        Self.monitor = monitor

        monitor.pathUpdateHandler = { path in
            let nowOnline = path.status == .satisfied
            guard nowOnline != Self.isOnline else { return }
            Self.isOnline = nowOnline

            Task {
                await EventBus.shared.emit(.networkChanged(isOnline: nowOnline))
            }

            print("[NETWORK] Status changed: \(nowOnline ? "online" : "offline")")
        }

        monitor.start(queue: DispatchQueue.global(qos: .background))
        print("[NETWORK] NWPathMonitor started — watching connectivity.")
    }

    static func currentlyOnline() -> Bool { isOnline }
}
