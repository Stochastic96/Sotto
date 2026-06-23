import Foundation

// MARK: - DownloadsObserver
//
// Watches ~/Downloads using DispatchSource (kernel-level FSEvents — 0 CPU when idle).
// When a new completed file appears, emits .fileArrived so EventHandler can suggest an action.
//
// Example flows:
//   repo.zip arrives      → "📦 Unzip repo.zip?"        → command: "unzip ~/Downloads/repo.zip"
//   App.dmg arrives       → "💿 Install App?"            → command: nil (user confirms first)
//   report.pdf arrives    → "📄 Summarize report.pdf?"   → command: "summarize pdf ~/Downloads/report.pdf"
//   script.sh arrives     → "📝 Review script.sh?"       → command: "review file ~/Downloads/script.sh"

enum DownloadsObserver {

    private static let downloadsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")

    // Partial-download extensions to ignore — file isn't ready yet
    private static let partialExtensions: Set<String> = ["crdownload", "download", "part", "tmp", "dwl"]

    static func start() {
        Task.detached(priority: .background) { await watch() }
    }

    // MARK: - FSEvents-based watcher

    private static func watch() async {
        var knownFiles = currentFiles()

        // Open directory as a file descriptor for DispatchSource
        let fd = open(downloadsURL.path, O_EVTONLY)
        guard fd >= 0 else {
            print("[DOWNLOADS] Cannot open ~/Downloads for watching — observer disabled.")
            return
        }

        let (stream, continuation) = AsyncStream<Void>.makeStream()

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,          // fires when directory contents change
            queue: .global(qos: .background)
        )
        source.setEventHandler { continuation.yield(()) }
        source.setCancelHandler {
            close(fd)
            continuation.finish()
        }
        source.resume()
        print("[DOWNLOADS] Watching ~/Downloads for new files.")

        for await _ in stream {
            let current = currentFiles()
            let arrived = current.subtracting(knownFiles)
            knownFiles = current

            for filename in arrived {
                let ext = (filename as NSString).pathExtension.lowercased()
                // Skip hidden files and partial downloads
                guard !filename.hasPrefix("."), !partialExtensions.contains(ext) else { continue }

                // Brief pause — ensures the file is fully written before we act on it
                try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 s

                let url = downloadsURL.appendingPathComponent(filename)
                await EventBus.shared.emit(.fileArrived(url: url, ext: ext))
            }
        }
    }

    private static func currentFiles() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path)) ?? [])
    }
}
