import Foundation
import Network

enum NetworkObserver {
    private static var monitor: NWPathMonitor?
    private static var isOnline = true

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
