import AppKit
import Foundation

private var globalCleanup: (() -> Void)?

@main
@MainActor
struct SottoApp {
    private static var delegate: AppDelegate?
    
    static func main() {
        #if DEBUG
        if CommandLine.arguments.contains("--run-tests") || CommandLine.arguments.contains("--evaluate") || CommandLine.arguments.contains("--run-evaluation") {
            setvbuf(stdout, nil, _IONBF, 0)
            setvbuf(stderr, nil, _IONBF, 0)
        }

        if CommandLine.arguments.contains("--run-tests") {
            var finished = false
            var testSuccess = false
            Task {
                testSuccess = await runSottoIntegrationTests()
                finished = true
            }
            while !finished {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            exit(testSuccess ? 0 : 1)
        }
        #endif

        if CommandLine.arguments.contains("--evaluate") || CommandLine.arguments.contains("--run-evaluation") {
            var finished = false
            var success = false
            let forceMock = CommandLine.arguments.contains("--mock")
            Task {
                success = await JarvisEvaluation.run(forceMock: forceMock)
                finished = true
            }
            while !finished {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            exit(success ? 0 : 1)
        }

        // AppKit app loop runs on MainActor/MainThread
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let del = AppDelegate()
        self.delegate = del
        app.delegate = del
        app.run()
    }
}

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
            // _Exit is async-signal-safe. exit() is NOT — it triggers C++ global
            // destructors (MLX Scheduler dtor → Metal ObjC call) which try to acquire
            // the ObjC runtime lock. If the signal fires while NSApplication.terminate:
            // already holds that lock (e.g. during graceful quit), the recursive lock
            // attempt causes SIGKILL. applicationWillTerminate handles cleanup anyway.
            _Exit(0)
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            controller?.settings.showSettings()
        }
        return true
    }
}
