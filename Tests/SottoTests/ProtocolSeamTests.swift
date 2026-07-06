import Testing
import Foundation
@testable import SottoCore

// These tests exist to prove the protocol seams introduced by the protocol-orientation
// pass are actually reachable and usable from the test target (which depends only on
// SottoCore). Each fake conforms to a seam and is exercised as an existential — exactly how
// a tool/coordinator/queue holds it in production. If a protocol ever drifts back into the
// AppKit-only executable target, these tests stop compiling.

// MARK: - SystemControlling

@Suite("SystemControlling seam")
struct SystemControllingSeamTests {
    /// A spy standing in for LiveSystemControl; records the calls a tool would make.
    final class SpySystemControl: SystemControlling, @unchecked Sendable {
        var volume: Float = 0.5
        var brightness: Float = 0.5
        var muted = false
        private(set) var setVolumeCalls: [Float] = []

        func getVolume() -> Float { volume }
        func setVolume(_ v: Float) -> Bool { setVolumeCalls.append(v); volume = v; return true }
        func isMuted() -> Bool { muted }
        func setMuted(_ m: Bool) -> Bool { muted = m; return true }
        func getBrightness() -> Float { brightness }
        func setBrightness(_ v: Float) -> Bool { brightness = v; return true }
    }

    @Test func recordsAndReflectsCalls() {
        let spy = SpySystemControl()
        let system: any SystemControlling = spy
        _ = system.setVolume(70)
        _ = system.setMuted(true)
        #expect(spy.setVolumeCalls == [70])
        #expect(system.isMuted())
        #expect(system.getVolume() == 70)
    }
}

// MARK: - SubAgent

@Suite("SubAgent seam")
struct SubAgentSeamTests {
    struct StubAgent: SubAgent {
        let canned: String
        func run(task: String) async -> String { "handled(\(task)):\(canned)" }
    }

    @Test func returnsCannedOutput() async {
        let agent: any SubAgent = StubAgent(canned: "ok")
        #expect(await agent.run(task: "lock screen") == "handled(lock screen):ok")
    }
}

// MARK: - CommandRecording

@Suite("CommandRecording seam")
struct CommandRecordingSeamTests {
    final class SpyRecorder: CommandRecording, @unchecked Sendable {
        private(set) var calls: [(tool: String, json: String)] = []
        func recordToolCall(toolName: String, argumentsJson: String) async {
            calls.append((toolName, argumentsJson))
        }
    }

    @Test func capturesRecordedCalls() async {
        let spy = SpyRecorder()
        let recorder: any CommandRecording = spy
        await recorder.recordToolCall(toolName: "set_volume", argumentsJson: #"{"level":70}"#)
        #expect(spy.calls.count == 1)
        #expect(spy.calls.first?.tool == "set_volume")
    }
}

// MARK: - Microtask + MicrotaskExecutor

@Suite("Microtask seam")
struct MicrotaskSeamTests {
    struct EchoExecutor: MicrotaskExecutor {
        func execute(_ task: Microtask) async -> (output: String?, error: String?) {
            (task.goal.uppercased(), nil)
        }
    }

    @Test func newTaskDefaults() {
        let task = Microtask(name: "t", goal: "check git", priority: 5)
        #expect(task.status == .pending)
        #expect(task.priority == 5)
        #expect(task.retryCount == 0)
    }

    @Test func codableRoundTripPreservesFields() throws {
        let task = Microtask(name: "n", goal: "g", priority: 2)
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(Microtask.self, from: data)
        #expect(decoded.name == "n")
        #expect(decoded.goal == "g")
        #expect(decoded.priority == 2)
        #expect(decoded.status == .pending)
    }

    @Test func executorSeamRuns() async {
        let executor: any MicrotaskExecutor = EchoExecutor()
        let (out, err) = await executor.execute(Microtask(name: "t", goal: "check git"))
        #expect(out == "CHECK GIT")
        #expect(err == nil)
    }
}

// MARK: - TextInjecting

@Suite("TextInjecting seam")
struct TextInjectingSeamTests {
    final class SpyInjector: TextInjecting, @unchecked Sendable {
        private(set) var injected: [String] = []
        var selection: String? = "hello"
        func inject(_ text: String, fileURL: URL?, targetPID: pid_t?) async { injected.append(text) }
        func injectUnicode(_ text: String, targetPID: pid_t?) async { injected.append(text) }
        func grabActiveSelection(targetPID: pid_t?) async -> String? { selection }
        func pressReturn(targetPID: pid_t?) async {}
        func pressSearchShortcut(_ type: SearchShortcutType, targetPID: pid_t?) async {}
    }

    @Test func injectsViaConvenienceDefaultArgs() async {
        let spy = SpyInjector()
        let injector: any TextInjecting = spy
        // Exercises the SottoCore default-argument convenience (fileURL/targetPID omitted).
        await injector.inject("polished text")
        #expect(spy.injected == ["polished text"])
        #expect(await injector.grabActiveSelection() == "hello")
    }

    @Test func searchShortcutRawValues() {
        #expect(SearchShortcutType.find.rawValue == "find")
        #expect(SearchShortcutType.location.rawValue == "location")
    }
}
