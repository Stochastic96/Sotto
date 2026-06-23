import Foundation

public struct ExecutionResult {
    public let success: Bool
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public class SwiftScriptRunner {
    public static func run(scriptCode: String) async -> ExecutionResult {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "sotto_script_\(UUID().uuidString).swift"
        let fileURL = tempDir.appendingPathComponent(fileName)
        
        do {
            try scriptCode.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            return ExecutionResult(success: false, stdout: "", stderr: "Failed to write temp script: \(error.localizedDescription)", exitCode: -1)
        }
        
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [fileURL.path]
        
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            
            let stdoutStr = String(data: outData, encoding: .utf8) ?? ""
            let stderrStr = String(data: errData, encoding: .utf8) ?? ""
            
            let success = (process.terminationStatus == 0)
            return ExecutionResult(success: success, stdout: stdoutStr, stderr: stderrStr, exitCode: process.terminationStatus)
        } catch {
            return ExecutionResult(success: false, stdout: "", stderr: "Failed to run swift process: \(error.localizedDescription)", exitCode: -1)
        }
    }
}
