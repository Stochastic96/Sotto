import Foundation
import Network

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "sotto.network.monitor")
    
    @Published private(set) var isReachable = true
    
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
                if let httpResponse = response as? HTTPURLResponse {
                    if httpResponse.statusCode == 200 {
                        return data
                    } else if httpResponse.statusCode == 429 {
                        print("[NETWORK-RETRY] Rate limited (429) for \(req.url?.host ?? ""). Retrying...")
                    } else {
                        throw NSError(domain: "SottoNetwork", code: -102, userInfo: [NSLocalizedDescriptionKey: "HTTP status code error: \(httpResponse.statusCode)"])
                    }
                } else {
                    throw NSError(domain: "SottoNetwork", code: -103, userInfo: [NSLocalizedDescriptionKey: "Invalid URL response"])
                }
            } catch {
                if attempt >= maxRetries {
                    throw error
                }
                print("[NETWORK-RETRY] Attempt \(attempt) failed: \(error.localizedDescription). Retrying in \(delay)s...")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2.0 // Exponential backoff
            }
        }
    }

    static func fetchData(from url: URL, maxRetries: Int = 3) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 5.0
        return try await fetchData(for: request, maxRetries: maxRetries)
    }
}
