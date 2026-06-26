import Foundation

extension AppController {
    func scheduleErrorRecovery() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, case .error = self.state else { return }
            self.state = .idle
        }
    }
}
