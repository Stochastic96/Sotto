 import AppKit
import Foundation

if CommandLine.arguments.contains("--run-tests") {
    let semaphore = DispatchSemaphore(value: 0)
    var testSuccess = false
    Task {
        testSuccess = await runSottoIntegrationTests()
        semaphore.signal()
    }
    semaphore.wait()
    exit(testSuccess ? 0 : 1)
}

private var globalCleanup: (() -> Void)?

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logURL = SettingsController.sottoLogURL
        let logPath = logURL.path
        
        // Ensure parent directory exists
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: nil)
        freopen(logPath, "w", stdout)
        setvbuf(stdout, nil, _IONBF, 0)
        
        print("[SOTTO-MAIN] Sotto started logging to: \(logPath)")
        
        let controller = AppController()
        self.controller = controller
        controller.start()
        
        // Register POSIX signal handlers for graceful cleanup when killed from terminal
        globalCleanup = { [weak controller] in
            controller?.cleanup()
        }
        
        let handler: @convention(c) (Int32) -> Void = { sig in
            print("[SOTTO-MAIN] Intercepted signal \(sig). Executing cleanup...")
            globalCleanup?()
            exit(0)
        }
        signal(SIGINT, handler)
        signal(SIGTERM, handler)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.cleanup()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            print("[APP] Opened URL: \(url.absoluteString)")
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { continue }
            if components.host == "command" {
                if let queryItems = components.queryItems,
                   let text = queryItems.first(where: { $0.name == "text" })?.value {
                    Task { @MainActor in
                        NotificationCenter.default.post(
                            name: NSNotification.Name("SottoIncomingCommand"),
                            object: nil,
                            userInfo: ["text": text]
                        )
                    }
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
