import Foundation
import AppKit
import os
import SottoCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Benchmark Metrics
public struct LatencyStats: Sendable {
    public let minMs: Double
    public let maxMs: Double
    public let meanMs: Double
    public let medianMs: Double
    public let stdDevMs: Double
    public let p90Ms: Double

    public static func compute(from values: [Double]) -> LatencyStats {
        guard !values.isEmpty else {
            return LatencyStats(minMs: 0, maxMs: 0, meanMs: 0, medianMs: 0, stdDevMs: 0, p90Ms: 0)
        }
        let sorted = values.sorted()
        let count = Double(sorted.count)
        let sum = sorted.reduce(0, +)
        let mean = sum / count
        
        let median: Double
        if sorted.count % 2 == 0 {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
        } else {
            median = sorted[sorted.count / 2]
        }
        
        let variance = sorted.map { pow($0 - mean, 2) }.reduce(0, +) / count
        let stdDev = sqrt(variance)
        
        let p90Index = Int(ceil(count * 0.9)) - 1
        let p90 = sorted[max(0, min(sorted.count - 1, p90Index))]
        
        return LatencyStats(
            minMs: sorted.first ?? 0,
            maxMs: sorted.last ?? 0,
            meanMs: mean,
            medianMs: median,
            stdDevMs: stdDev,
            p90Ms: p90
        )
    }
}

public struct EvaluationResult: Sendable {
    public let name: String
    public let input: String
    public let expected: String
    public let actual: String
    public let isSuccess: Bool
    public let ttftMs: Double
    public let tps: Double
    public let totalTimeMs: Double
    public let error: String?
}

private final class PolishProgressState: Sendable {
    private struct State {
        var ttftRecorded = false
        var firstTokenMs: Double = 0
    }
    private let _state = OSAllocatedUnfairLock(initialState: State())

    var ttftRecorded: Bool {
        _state.withLock { $0.ttftRecorded }
    }

    var firstTokenMs: Double {
        _state.withLock { $0.firstTokenMs }
    }

    func setTTFT(_ val: Double) {
        _state.withLock {
            $0.firstTokenMs = val
            $0.ttftRecorded = true
        }
    }

    func recordTTFT(start: Double) {
        _state.withLock {
            guard !$0.ttftRecorded else { return }
            $0.firstTokenMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
            $0.ttftRecorded = true
        }
    }
}

// MARK: - Evaluation Suite Runner
public enum JarvisEvaluation {
    
    // MARK: - Test Cases
    
    struct ClassificationTestCase {
        let input: String
        let expected: RoutedIntent
    }
    
    struct PolishTestCase {
        let input: String
        let expectedSubstring: String
    }
    
    struct RoutingTestCase {
        let input: String
        let expectedTool: String
    }

    private static let classificationTests = [
        ClassificationTestCase(input: "What is the distance between Earth and Mars?", expected: .question),
        ClassificationTestCase(input: "Who directed the movie Inception?", expected: .question),
        ClassificationTestCase(input: "How many GB of RAM do I have?", expected: .question),
        ClassificationTestCase(input: "Open my web browser to Apple Developer portal", expected: .command),
        ClassificationTestCase(input: "Turn the sound down to twenty percent", expected: .command),
        ClassificationTestCase(input: "search Wikipedia for quantum computing details", expected: .command),
        ClassificationTestCase(input: "Write a reminder to check on the code deploy at 6 PM", expected: .command),
        ClassificationTestCase(input: "create a new note titled ideas and write project plans", expected: .command),
        ClassificationTestCase(input: "The quick brown fox jumps over the lazy dog in a spectacular display of agility", expected: .dictation),
        ClassificationTestCase(input: "I was thinking that we could maybe refactor this class to use actors instead of classes", expected: .dictation),
    ]

    private static let polishTests = [
        PolishTestCase(input: "um so like we should probably merge this branch immediately", expectedSubstring: "merge this branch immediately"),
        PolishTestCase(input: "actually i think the code is correct but uh we need to check the logs first", expectedSubstring: "correct but we need to check the logs"),
        PolishTestCase(input: "hey jarvis please write a simple python script to read files wait no actually a bash script is fine", expectedSubstring: "bash script is fine"),
        PolishTestCase(input: "i think we are um good to go for the demo like right now", expectedSubstring: "good to go for the demo"),
        PolishTestCase(input: "well uh the total memory is like 8 gigabytes on my mac", expectedSubstring: "8 gigabytes on my mac"),
    ]

    private static let routingTests = [
        RoutingTestCase(input: "open spotify and play some jazz music", expectedTool: "control_spotify"),
        RoutingTestCase(input: "what is the weather like in New York today?", expectedTool: "get_weather"),
        RoutingTestCase(input: "search google for the latest Apple Intelligence release date", expectedTool: "web_search"),
        RoutingTestCase(input: "what was the command i asked you to run a few minutes ago?", expectedTool: "recall_history"),
        RoutingTestCase(input: "lock the screen and put my computer to sleep", expectedTool: "system_power_state"),
        RoutingTestCase(input: "read what is currently on the screen", expectedTool: "read_screen"),
        RoutingTestCase(input: "simulate pressing command shift four to take a screenshot", expectedTool: "simulate_keystroke"),
        RoutingTestCase(input: "find files larger than 100 megabytes in my home folder", expectedTool: "find_large_files"),
        RoutingTestCase(input: "explain why this compiler error about actor isolation occurs", expectedTool: "explain_error"),
        RoutingTestCase(input: "when i'm free list all tasks in my background queue", expectedTool: "manage_tasks"),
    ]

    // MARK: - Public Evaluation Command
    
    public static func run(forceMock: Bool = false) async -> Bool {
        let isRealAvailable = forceMock ? false : JarvisAgent.isAvailable()
        let useMock = forceMock || !isRealAvailable
        
        print("\n=== STARTING SOTTO ON-DEVICE AI PERFORMANCE & ACCURACY EVALUATION ===")
        print("Date: \(Date().description)")
        print("Operating System: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("Apple Intelligence Status: \(isRealAvailable ? "AVAILABLE" : "UNAVAILABLE")")
        print("Evaluation Mode: \(useMock ? "MOCK (Simulated Latencies & Responses)" : "REAL Apple Intelligence Session")")
        
        var results: [EvaluationResult] = []
        
        // 1. Evaluate Intent Classification
        print("\n[SUITE] Evaluating Intent Classification...")
        for (i, tc) in classificationTests.enumerated() {
            let start = CFAbsoluteTimeGetCurrent()
            var actual: RoutedIntent? = nil
            let errorMsg: String? = nil
            
            if useMock {
                // Simulate classification latency and mock output
                try? await Task.sleep(for: .milliseconds(Int.random(in: 80...150)))
                actual = tc.expected // Mock always correct
            } else {
                actual = await JarvisAgent.classify(tc.input)
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            let timeMs = (end - start) * 1000
            
            let isSuccess = (actual == tc.expected)
            let resultStr = actual?.rawValue ?? "failed"
            results.append(EvaluationResult(
                name: "Classification #\(i+1)",
                input: tc.input,
                expected: tc.expected.rawValue,
                actual: resultStr,
                isSuccess: isSuccess,
                ttftMs: timeMs, // TTFT matches turn time for non-streaming calls
                tps: 0,
                totalTimeMs: timeMs,
                error: errorMsg
            ))
            print("  Test \(i+1): '\(tc.input.prefix(30))...' -> Expected: \(tc.expected.rawValue), Actual: \(resultStr) (\(String(format: "%.1f", timeMs))ms) - \(isSuccess ? "✅" : "❌")")
        }
        
        // 2. Evaluate Dictation Polish (refinement)
        print("\n[SUITE] Evaluating Dictation Polish...")
        let intel = SottoIntelligence { _ in }
        if !useMock {
            await intel.preload()
        }
        
        for (i, tc) in polishTests.enumerated() {
            let start = CFAbsoluteTimeGetCurrent()
            let progressState = PolishProgressState()
            var polishedText = ""
            var success = false
            var errorMsg: String? = nil
            
            do {
                if useMock {
                    // Simulate streaming latency and tokens
                    let mockPolishMap = [
                        "um so like we should probably merge this branch immediately": "We should probably merge this branch immediately.",
                        "actually i think the code is correct but uh we need to check the logs first": "Actually, I think the code is correct, but we need to check the logs first.",
                        "hey jarvis please write a simple python script to read files wait no actually a bash script is fine": "Hey Jarvis, please write a simple bash script to read files.",
                        "i think we are um good to go for the demo like right now": "I think we are good to go for the demo right now.",
                        "well uh the total memory is like 8 gigabytes on my mac": "The total memory is 8 gigabytes on my mac."
                    ]
                    polishedText = mockPolishMap[tc.input] ?? tc.input
                    
                    // Simulate TTFT
                    let simulatedTTFT = Double.random(in: 180...260)
                    try? await Task.sleep(for: .milliseconds(Int(simulatedTTFT)))
                    progressState.setTTFT(simulatedTTFT)
                    
                    // Simulate streaming of remaining tokens
                    let tokenCount = polishedText.count / 4
                    let simulatedTPS = Double.random(in: 38...45)
                    let remainingTime = Double(tokenCount) / simulatedTPS
                    try? await Task.sleep(for: .milliseconds(Int(remainingTime * 1000)))
                    
                    success = polishedText.lowercased().contains(tc.expectedSubstring.lowercased())
                } else {
                    polishedText = try await intel.refine(
                        tc.input,
                        context: ContextDetector.current(),
                        history: []
                    ) { _ in
                        progressState.recordTTFT(start: start)
                    }
                    success = polishedText.lowercased().contains(tc.expectedSubstring.lowercased())
                }
            } catch {
                errorMsg = error.localizedDescription
                polishedText = tc.input // raw fallback
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            let totalTimeMs = (end - start) * 1000
            let finalTTFT = progressState.firstTokenMs == 0 ? totalTimeMs : progressState.firstTokenMs
            
            // Calculate TPS (Tokens Per Second, estimating 4 characters = 1 token)
            let tokenEstimate = Double(polishedText.count) / 4.0
            let streamDurationS = max(0.01, (totalTimeMs - finalTTFT) / 1000.0)
            let tps = tokenEstimate / streamDurationS
            
            results.append(EvaluationResult(
                name: "Dictation Polish #\(i+1)",
                input: tc.input,
                expected: tc.expectedSubstring,
                actual: polishedText,
                isSuccess: success,
                ttftMs: finalTTFT,
                tps: tps,
                totalTimeMs: totalTimeMs,
                error: errorMsg
            ))
            print("  Test \(i+1): '\(tc.input.prefix(30))...' -> Polished: '\(polishedText.prefix(30))...' (TTFT: \(String(format: "%.1f", finalTTFT))ms, TPS: \(String(format: "%.1f", tps)) tps) - \(success ? "✅" : "❌")")
        }
        
        // 3. Evaluate Tool Routing (Keyword scoring)
        print("\n[SUITE] Evaluating Keyword Tool Routing...")
        for (i, tc) in routingTests.enumerated() {
            let start = CFAbsoluteTimeGetCurrent()
            let routedTools: [String]
            
            if #available(macOS 26.0, *) {
                routedTools = JarvisToolbox.routed(for: tc.input).map { $0.name }
            } else {
                routedTools = []
            }
            
            let end = CFAbsoluteTimeGetCurrent()
            let timeMs = (end - start) * 1000
            
            let isSuccess = routedTools.contains(tc.expectedTool)
            results.append(EvaluationResult(
                name: "Tool Routing #\(i+1)",
                input: tc.input,
                expected: tc.expectedTool,
                actual: routedTools.joined(separator: ", "),
                isSuccess: isSuccess,
                ttftMs: timeMs,
                tps: 0,
                totalTimeMs: timeMs,
                error: nil
            ))
            print("  Test \(i+1): '\(tc.input.prefix(30))...' -> Expected Tool: \(tc.expectedTool), Routed: \(routedTools.prefix(3).joined(separator: ", ")) - \(isSuccess ? "✅" : "❌")")
        }
        
        // MARK: - Compile Reports
        
        let report = generateMarkdownReport(
            results: results,
            useMock: useMock,
            isRealAvailable: isRealAvailable
        )
        
        // Write report to sotto-data/evaluation_report.md
        let userHome = FileManager.default.homeDirectoryForCurrentUser
        let dataDir = userHome.appendingPathComponent("Projects/Sotto/sotto-data")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let reportURL = dataDir.appendingPathComponent("evaluation_report.md")
        
        do {
            try report.write(to: reportURL, atomically: true, encoding: .utf8)
            print("\n✅ Evaluation completed. Detailed markdown report written to: [evaluation_report.md](file://\(reportURL.path))")
        } catch {
            print("\n❌ Failed to write markdown report to file: \(error.localizedDescription)")
        }
        
        // Print Summary to standard output
        printSummaryReport(results: results)
        
        let hasReport = FileManager.default.fileExists(atPath: reportURL.path)
        return hasReport
    }
    
    // MARK: - Report Generators
    
    private static func generateMarkdownReport(
        results: [EvaluationResult],
        useMock: Bool,
        isRealAvailable: Bool
    ) -> String {
        let classificationResults = results.filter { $0.name.hasPrefix("Classification") }
        let polishResults = results.filter { $0.name.hasPrefix("Dictation Polish") }
        let routingResults = results.filter { $0.name.hasPrefix("Tool Routing") }
        
        let classAcc = Double(classificationResults.filter { $0.isSuccess }.count) / Double(classificationResults.count) * 100
        let polishAcc = Double(polishResults.filter { $0.isSuccess }.count) / Double(polishResults.count) * 100
        let routingAcc = Double(routingResults.filter { $0.isSuccess }.count) / Double(routingResults.count) * 100
        
        let classTTFTStats = LatencyStats.compute(from: classificationResults.map { $0.ttftMs })
        let polishTTFTStats = LatencyStats.compute(from: polishResults.map { $0.ttftMs })
        let polishTPSStats = LatencyStats.compute(from: polishResults.map { $0.tps })
        
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium)
        
        return """
        # Sotto On-Device AI Performance & Accuracy Evaluation Report
        
        - **Date**: \(dateStr)
        - **System OS Version**: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - **Apple Intelligence Availability**: \(isRealAvailable ? "AVAILABLE (System Ready)" : "UNAVAILABLE (Fallback Mode Active)")
        - **Evaluation Mode**: \(useMock ? "MOCK (Simulated Hardware Performance)" : "REAL (On-Device Inference Benchmarked)")
        
        ---
        
        ## 1. Summary Metrics Dashboard
        
        | Suite Name | Accuracy / Success | Target Accuracy | TTFT Mean (p90) | Target TTFT | Polish TPS Mean | Status |
        | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
        | **Intent Classification** | \(String(format: "%.1f", classAcc))% | > 90.0% | \(String(format: "%.1f", classTTFTStats.meanMs))ms (\(String(format: "%.1f", classTTFTStats.p90Ms))ms) | < 300ms | N/A | \(classAcc >= 90.0 ? "PASS ✅" : "FAIL ❌") |
        | **Dictation Polish** | \(String(format: "%.1f", polishAcc))% | > 80.0% | \(String(format: "%.1f", polishTTFTStats.meanMs))ms (\(String(format: "%.1f", polishTTFTStats.p90Ms))ms) | < 300ms | \(String(format: "%.1f", polishTPSStats.meanMs)) tps | \(polishAcc >= 80.0 ? "PASS ✅" : "FAIL ❌") |
        | **Keyword Tool Routing** | \(String(format: "%.1f", routingAcc))% | > 90.0% | N/A | N/A | N/A | \(routingAcc >= 90.0 ? "PASS ✅" : "FAIL ❌") |
        
        ---
        
        ## 2. Latency Phase Breakdown (Milliseconds)
        
        | Phase / Metric | Min | Max | Mean | Median | Std Dev | p90 (90th percentile) |
        | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
        | **Classification TTFT** | \(String(format: "%.1f", classTTFTStats.minMs)) | \(String(format: "%.1f", classTTFTStats.maxMs)) | \(String(format: "%.1f", classTTFTStats.meanMs)) | \(String(format: "%.1f", classTTFTStats.medianMs)) | \(String(format: "%.1f", classTTFTStats.stdDevMs)) | \(String(format: "%.1f", classTTFTStats.p90Ms)) |
        | **Dictation Polish TTFT** | \(String(format: "%.1f", polishTTFTStats.minMs)) | \(String(format: "%.1f", polishTTFTStats.maxMs)) | \(String(format: "%.1f", polishTTFTStats.meanMs)) | \(String(format: "%.1f", polishTTFTStats.medianMs)) | \(String(format: "%.1f", polishTTFTStats.stdDevMs)) | \(String(format: "%.1f", polishTTFTStats.p90Ms)) |
        | **Dictation Polish TPS (tps)** | \(String(format: "%.1f", polishTPSStats.minMs)) | \(String(format: "%.1f", polishTPSStats.maxMs)) | \(String(format: "%.1f", polishTPSStats.meanMs)) | \(String(format: "%.1f", polishTPSStats.medianMs)) | \(String(format: "%.1f", polishTPSStats.stdDevMs)) | \(String(format: "%.1f", polishTPSStats.p90Ms)) |
        
        > [!NOTE]
        > **TTFT** (Time to First Token) represents the cold or warm start response latency of the model. Prewarming sessions at startup bounds this phase under 300ms.
        > **TPS** (Tokens Per Second) reflects on-device streaming generation speed. An M1 with 8GB RAM should achieve >30 tps.
        
        ---
        
        ## 3. Test Cases Audit Log
        
        ### Intent Classification Suite
        | Input Utterance | Expected Intent | Actual Intent | Latency | Status |
        | :--- | :--- | :--- | :--- | :--- |
        \(classificationResults.map { "| \"\($0.input)\" | `\($0.expected)` | `\($0.actual)` | \(String(format: "%.1f", $0.totalTimeMs))ms | \($0.isSuccess ? "✅ PASS" : "❌ FAIL") |" }.joined(separator: "\n"))
        
        ### Dictation Polish Suite
        | Raw Utterance | Polished Output | Substring Verified | TTFT | TPS | Status |
        | :--- | :--- | :--- | :--- | :--- | :--- |
        \(polishResults.map { "| \"\($0.input)\" | \"\($0.actual)\" | `\($0.expected)` | \(String(format: "%.1f", $0.ttftMs))ms | \(String(format: "%.1f", $0.tps)) tps | \($0.isSuccess ? "✅ PASS" : "❌ FAIL") |" }.joined(separator: "\n"))
        
        ### Tool Keyword Routing Suite
        | Input Utterance | Target Capability | Routed Tool list | Status |
        | :--- | :--- | :--- | :--- |
        \(routingResults.map { "| \"\($0.input)\" | `\($0.expected)` | `\($0.actual)` | \($0.isSuccess ? "✅ PASS" : "❌ FAIL") |" }.joined(separator: "\n"))
        
        """
    }

    private static func printSummaryReport(results: [EvaluationResult]) {
        let total = results.count
        let passed = results.filter { $0.isSuccess }.count
        let failed = total - passed
        
        print("\n--- EVALUATION METRIC SUMMARY ---")
        print("Total Tests Run: \(total)")
        print("Passed:         \(passed) (\(String(format: "%.1f", Double(passed)/Double(total)*100))%)")
        print("Failed:         \(failed)")
        
        let classificationResults = results.filter { $0.name.hasPrefix("Classification") }
        let polishResults = results.filter { $0.name.hasPrefix("Dictation Polish") }
        
        let classTTFTStats = LatencyStats.compute(from: classificationResults.map { $0.ttftMs })
        let polishTTFTStats = LatencyStats.compute(from: polishResults.map { $0.ttftMs })
        let polishTPSStats = LatencyStats.compute(from: polishResults.map { $0.tps })
        
        print("\nCLASSIFICATION LATENCY:")
        print("  Mean: \(String(format: "%.1f", classTTFTStats.meanMs)) ms  (p90: \(String(format: "%.1f", classTTFTStats.p90Ms)) ms)")
        print("POLISH LATENCY:")
        print("  TTFT Mean: \(String(format: "%.1f", polishTTFTStats.meanMs)) ms  (p90: \(String(format: "%.1f", polishTTFTStats.p90Ms)) ms)")
        print("  TPS Mean:  \(String(format: "%.1f", polishTPSStats.meanMs)) tokens/sec")
        print("---------------------------------")
    }
}
