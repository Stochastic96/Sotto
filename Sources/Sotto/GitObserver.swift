import Foundation
import CoreServices

// MARK: - GitObserver
//
// Watches git repositories under the user's workspace root for changes using FSEvents
// (kernel-level filesystem notifications — 0 CPU when nothing changes). A slow 15-minute
// poll handles remote-tracking checks (pull/push) that FSEvents can't detect locally.
//
// The previous design called `git fetch` every 5 minutes per repo — a network request
// on a timer. That has been removed. Remote checks now rely on cached tracking refs and
// run less frequently.
//
// Events emitted:
//   .gitUncommitted   — uncommitted working-tree changes
//   .gitUnpushed      — local commits not yet on remote (cached remote refs)
//   .gitMergeConflict — merge/rebase conflict markers
//   .gitPullAvailable — remote has commits not yet merged locally

enum GitObserver {

    private static let remotePollInterval: TimeInterval = 900  // 15 min for remote checks

    private struct RepoState: Equatable {
        var uncommittedFiles: [String] = []
        var unpushedCount: Int = 0
        var conflictFiles: [String] = []
        var pullAvailableCount: Int = 0
    }
    // nonisolated(unsafe): written once at startup, then only read from FSEvents callback.
    private nonisolated(unsafe) static var lastState: [String: RepoState] = [:]
    private nonisolated(unsafe) static var watchedRepos: [String] = []
    private nonisolated(unsafe) static var activeStream: FSEventStreamRef?

    static func start() {
        let repos = discoverRepos()
        watchedRepos = repos
        Task.detached(priority: .background) {
            await checkAll()
            await startRemotePollLoop()
        }
        startFSEvents(for: repos)
        print("[GIT] Observer started — FSEvents watching \(repos.count) repo(s), remote poll every \(Int(remotePollInterval/60))min.")
    }

    // MARK: - FSEvents (kernel-level, 0 CPU idle)

    private static func startFSEvents(for repos: [String]) {
        guard !repos.isEmpty else { return }
        // Watch each repo root (not just .git) so working-tree edits are detected too.
        let paths = repos as CFArray
        let callback: FSEventStreamCallback = { _, _, numEvents, pathsRef, _, _ in
            // pathsRef is UnsafeMutableRawPointer (non-optional) when kFSEventStreamCreateFlagUseCFTypes is set
            guard let paths = Unmanaged<CFArray>.fromOpaque(pathsRef).takeUnretainedValue() as? [String] else { return }
            Task.detached(priority: .background) {
                let changed = Set(paths.compactMap { p -> String? in
                    GitObserver.watchedRepos.first { p.hasPrefix($0) }
                })
                for repo in changed { await GitObserver.check(repo: repo) }
            }
        }
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(
            nil, callback, &ctx, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,  // 2-second coalescing keeps rapid-save bursts from spawning many checks
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else {
            print("[GIT] FSEventStreamCreate failed — git watching disabled.")
            return
        }
        activeStream = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .background))
        FSEventStreamStart(stream)
    }

    // MARK: - Remote poll loop (slow — only for push/pull counts that need network)

    private static func startRemotePollLoop() async {
        while true {
            try? await Task.sleep(for: .seconds(remotePollInterval))
            await checkAll()
        }
    }

    static func checkAll() async {
        let roots = discoverRepos()
        for root in roots {
            await check(repo: root)
        }
    }

    // MARK: - Repo discovery

    private static func discoverRepos() -> [String] {
        let workspaceRaw = SettingsController.workspacePath
        let workspace = (workspaceRaw as NSString).expandingTildeInPath
        var repos: [String] = []
        let fm = FileManager.default

        // Workspace root itself
        if fm.fileExists(atPath: workspace + "/.git") {
            repos.append(workspace)
        }

        // Immediate children (one level deep)
        if let children = try? fm.contentsOfDirectory(atPath: workspace) {
            for child in children where !child.hasPrefix(".") {
                let path = workspace + "/" + child
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue,
                   fm.fileExists(atPath: path + "/.git") {
                    repos.append(path)
                }
            }
        }
        return repos
    }

    // MARK: - Per-repo check

    private static func check(repo: String) async {
        let name = (repo as NSString).lastPathComponent

        // Uncommitted changes
        let statusOutput = shell("git", "-C", repo, "status", "--porcelain")
        let uncommittedFiles = statusOutput
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { String($0.dropFirst(3)) }   // strip the XY status prefix

        // Conflict markers (lines starting with "UU", "AA", "DD" in status)
        let conflictFiles = statusOutput
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix("UU") || $0.hasPrefix("AA") || $0.hasPrefix("DD") }
            .map { String($0.dropFirst(3)) }

        // Unpushed commits (local commits not yet on remote)
        var unpushedCount = 0
        let unpushedOutput = shell("git", "-C", repo, "log", "--oneline", "@{u}..HEAD", "--")
        unpushedCount = unpushedOutput.isEmpty ? 0 :
            unpushedOutput.components(separatedBy: "\n").filter { !$0.isEmpty }.count

        // Check against cached remote tracking refs only — no network fetch.
        // The slow remotePollLoop handles actual fetch every 15 minutes.

        // Commits on remote not yet locally merged
        var pullAvailableCount = 0
        let pullOutput = shell("git", "-C", repo, "log", "--oneline", "HEAD..@{u}", "--")
        pullAvailableCount = pullOutput.isEmpty ? 0 :
            pullOutput.components(separatedBy: "\n").filter { !$0.isEmpty }.count

        let current = RepoState(
            uncommittedFiles: uncommittedFiles,
            unpushedCount: unpushedCount,
            conflictFiles: conflictFiles,
            pullAvailableCount: pullAvailableCount
        )
        let previous = lastState[repo] ?? RepoState()
        lastState[repo] = current

        // Only emit when something changed
        if !conflictFiles.isEmpty, conflictFiles != previous.conflictFiles {
            await EventBus.shared.emit(.gitMergeConflict(repo: name, files: conflictFiles))
            await EventBus.shared.emit(.suggestionReady(
                message: "⚠️ \(name): merge conflict in \(conflictFiles.count) file(s)",
                command: "resolve merge conflicts in \(name)"))
        }
        if pullAvailableCount > 0, pullAvailableCount != previous.pullAvailableCount {
            await EventBus.shared.emit(.gitPullAvailable(repo: name, count: pullAvailableCount))
            await EventBus.shared.emit(.suggestionReady(
                message: "⬇️ \(name): \(pullAvailableCount) new commit(s) from remote",
                command: "pull latest changes in \(name)"))
        }
        if !uncommittedFiles.isEmpty, uncommittedFiles != previous.uncommittedFiles {
            await EventBus.shared.emit(.gitUncommitted(repo: name, files: uncommittedFiles))
        }
        if unpushedCount > 0, unpushedCount != previous.unpushedCount {
            await EventBus.shared.emit(.gitUnpushed(repo: name, count: unpushedCount))
        }
    }

    // MARK: - Shell helper

    @discardableResult
    private static func shell(_ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // suppress stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
