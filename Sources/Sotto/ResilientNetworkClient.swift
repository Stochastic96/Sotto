import Foundation
import Network
import Observation
import os

@MainActor @Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sotto.network.monitor")

    private(set) var isReachable = true
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.isReachable = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }
    
    func checkReachable() -> Bool {
        return isReachable
    }
}

struct ResilientNetworkClient {
    private static let log = Logger(subsystem: "local.sotto.app", category: "network")

    static func fetchData(for request: URLRequest, maxRetries: Int = 3) async throws -> Data {
        let isReachable = await NetworkMonitor.shared.checkReachable()
        guard isReachable else {
            throw NSError(domain: "SottoNetwork", code: -101, userInfo: [NSLocalizedDescriptionKey: "No internet connection detected."])
        }
        
        var attempt = 0
        var delay: Double = 0.5 // Start with 500ms delay
        
        while true {
            attempt += 1
            var req = request
            if req.value(forHTTPHeaderField: "User-Agent") == nil {
                req.setValue("JarvisSottoAgent/1.0", forHTTPHeaderField: "User-Agent")
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "SottoNetwork", code: -103, userInfo: [NSLocalizedDescriptionKey: "Invalid URL response"])
                }

                // Treat any 2xx as success
                if (200...299).contains(httpResponse.statusCode) {
                    return data
                }

                // Respect Retry-After for 429/503 when present
                if httpResponse.statusCode == 429 || httpResponse.statusCode == 503,
                   let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Double(retryAfter) {
                    if attempt >= maxRetries {
                        throw NSError(domain: "SottoNetwork", code: httpResponse.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode) after \(maxRetries) retries"])
                    }
                    ResilientNetworkClient.log.info("Rate limited/status \(httpResponse.statusCode), retrying after \(seconds, privacy: .public)s…")
                    try await Task.sleep(for: .seconds(seconds))
                    continue
                }

                // For other 4xx/5xx, throw immediately unless we have retries left
                let err = NSError(domain: "SottoNetwork", code: httpResponse.statusCode,
                                   userInfo: [NSLocalizedDescriptionKey: "HTTP status code error: \(httpResponse.statusCode)"])
                throw err

            } catch {
                if attempt >= maxRetries {
                    throw error
                }
                let jitter = Double.random(in: 0...(delay * 0.2))
                ResilientNetworkClient.log.warning("[NETWORK-RETRY] Attempt \(attempt) failed: \(error.localizedDescription, privacy: .public). Retrying in \(delay + jitter, privacy: .public)s…")
                try await Task.sleep(for: .seconds(delay + jitter))
                delay = min(delay * 2.0, 8.0) // Exponential backoff with cap
            }
        }
    }

    static func fetchData(from url: URL, maxRetries: Int = 3) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        return try await fetchData(for: request, maxRetries: maxRetries)
    }
}
