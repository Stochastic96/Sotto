import Foundation
import CoreWLAN
import IOKit.ps

struct SystemDiagnostics {
    
    // --- Wifi SSID ---
    static func getWifiSSID() -> String {
        let client = CWInterface()
        return client.ssid() ?? "Not Connected"
    }
    
    // --- Battery Level ---
    static func getBatteryPercentage() -> String {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array
        for source in sources {
            if let description = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any],
               let currentCapacity = description[kIOPSCurrentCapacityKey] as? Int,
               let maxCapacity = description[kIOPSMaxCapacityKey] as? Int {
                let percentage = Int(Double(currentCapacity) / Double(maxCapacity) * 100.0)
                return "\(percentage)%"
            }
        }
        return "Unknown"
    }
    
    // --- Free Disk Space ---
    static func getFreeDiskSpace() -> String {
        let documentDirectoryPath = NSHomeDirectory()
        do {
            let systemAttributes = try FileManager.default.attributesOfFileSystem(forPath: documentDirectoryPath)
            if let freeSpace = systemAttributes[FileAttributeKey.systemFreeSize] as? NSNumber {
                let freeSpaceGB = freeSpace.doubleValue / (1024.0 * 1024.0 * 1024.0)
                return String(format: "%.1f GB", freeSpaceGB)
            }
        } catch {
            print("[DIAGNOSTICS] Error reading disk space: \(error)")
        }
        return "Unknown"
    }
    
    // --- RAM Memory Info ---
    struct RAMStat {
        let totalGB: Double
        let freeGB: Double
        let usedPercent: Double
        let wiredGB: Double
        let activeGB: Double
        let compressedGB: Double
    }
    
    static func getRAMUsage() -> RAMStat {
        var size = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let hostPort = mach_host_self()
        
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        
        let memsize = ProcessInfo.processInfo.physicalMemory
        let totalGB = Double(memsize) / (1024.0 * 1024.0 * 1024.0)
        
        guard result == KERN_SUCCESS else {
            return RAMStat(totalGB: totalGB, freeGB: 0, usedPercent: 0, wiredGB: 0, activeGB: 0, compressedGB: 0)
        }
        
        let pageSize = Double(vm_kernel_page_size)
        let freePages = Double(stats.free_count + stats.speculative_count)
        let freeGB = (freePages * pageSize) / (1024.0 * 1024.0 * 1024.0)
        let wiredGB = (Double(stats.wire_count) * pageSize) / (1024.0 * 1024.0 * 1024.0)
        let activeGB = (Double(stats.active_count) * pageSize) / (1024.0 * 1024.0 * 1024.0)
        let compressedGB = (Double(stats.compressor_page_count) * pageSize) / (1024.0 * 1024.0 * 1024.0)
        
        let usedGB = totalGB - freeGB
        let usedPercent = (usedGB / totalGB) * 100.0
        
        return RAMStat(
            totalGB: totalGB,
            freeGB: freeGB,
            usedPercent: usedPercent,
            wiredGB: wiredGB,
            activeGB: activeGB,
            compressedGB: compressedGB
        )
    }
    
    // --- Top Memory Consumers ---
    static func getTopMemoryProcesses() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "ps -A -o %mem,comm -r | head -n 6"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines).dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                return lines.map { line -> String in
                    let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                    guard parts.count == 2 else { return "" }
                    let mem = parts[0]
                    let path = String(parts[1])
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    return "| \(name) | \(mem)% |"
                }.filter { !$0.isEmpty }.joined(separator: "\n")
            }
        } catch {
            print("[DIAGNOSTICS] Error executing ps command: \(error)")
        }
        return ""
    }
    
    // --- Web Geocoding ---
    struct NominatimResult: Codable {
        let display_name: String
        let lat: String
        let lon: String
    }
    
    static func geocodeLocation(placeName: String) async -> NominatimResult? {
        guard let encodedName = placeName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://nominatim.openstreetmap.org/search?q=\(encodedName)&format=json&limit=1") else {
            return nil
        }
        
        do {
            let data = try await ResilientNetworkClient.fetchData(from: url)
            let results = try JSONDecoder().decode([NominatimResult].self, from: data)
            return results.first
        } catch {
            print("[DIAGNOSTICS] Geocoding failed for \(placeName): \(error.localizedDescription)")
            return nil
        }
    }

    // --- Wikipedia Search ---
    struct WikiResult {
        let title: String
        let extract: String
        let url: String
    }
    
    static func queryWikipedia(query: String) async -> WikiResult? {
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchUrl = URL(string: "https://en.wikipedia.org/w/api.php?action=opensearch&search=\(encodedQuery)&limit=1&namespace=0&format=json") else {
            return nil
        }
        
        do {
            let data = try await ResilientNetworkClient.fetchData(from: searchUrl)
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [Any],
                  jsonArray.count >= 2,
                  let titles = jsonArray[1] as? [String],
                  let title = titles.first else {
                return nil
            }
            
            guard let encodedTitle = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let summaryUrl = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encodedTitle)") else {
                return nil
            }
            
            let summaryData = try await ResilientNetworkClient.fetchData(from: summaryUrl)
            if let dict = try JSONSerialization.jsonObject(with: summaryData) as? [String: Any],
               let extract = dict["extract"] as? String,
               !extract.isEmpty {
                let titleDisplay = dict["title"] as? String ?? title
                let contentUrls = dict["content_urls"] as? [String: Any]
                let desktop = contentUrls?["desktop"] as? [String: Any]
                let sourceUrl = desktop?["page"] as? String ?? "https://en.wikipedia.org/wiki/\(encodedTitle)"
                
                return WikiResult(title: titleDisplay, extract: extract, url: sourceUrl)
            }
        } catch {
            print("[DIAGNOSTICS] Wikipedia query failed for \(query): \(error.localizedDescription)")
        }
        return nil
    }
}
