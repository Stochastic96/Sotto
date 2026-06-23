import Foundation

func runCommand(executable: String, arguments: [String]) -> (success: Bool, exitCode: Int32, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    
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
        
        return (process.terminationStatus == 0, process.terminationStatus, stdoutStr, stderrStr)
    } catch {
        return (false, -1, "", "Failed to launch \(executable): \(error.localizedDescription)")
    }
}

func main() {
    print("=== INTEGRATION TEST WRAPPER ===")
    print("Building Sotto executable target...")
    
    let buildResult = runCommand(executable: "/usr/bin/swift", arguments: ["build"])
    if !buildResult.success {
        print("❌ Build failed!")
        print(buildResult.stderr)
        print(buildResult.stdout)
        exit(1)
    }
    print("✅ Build succeeded.")
    
    print("\nRunning Sotto Integration Tests...")
    let runResult = runCommand(executable: ".build/debug/Sotto", arguments: ["--run-tests"])
    
    print(runResult.stdout)
    if !runResult.stderr.isEmpty {
        print("Stderr output:")
        print(runResult.stderr)
    }
    
    if runResult.success {
        print("\n✅ Sotto Integration Tests completed successfully.")
        exit(0)
    } else {
        print("\n❌ Sotto Integration Tests failed.")
        exit(runResult.exitCode)
    }
}

main()
