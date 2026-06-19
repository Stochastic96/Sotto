import AppKit
import CoreGraphics

/// Drives the Claude desktop app's **quick-entry popover** (the small "Quickly share
/// content with Claude" panel) WITHOUT opening the full app window.
///
/// The user's Claude quick-entry trigger is **double-tap Option** — a modifier *gesture*,
/// not a key chord. So we synthesize two quick taps of the Option key, then it's just
/// text injection + Return (exactly the user's intuition):
///   1. tap Option, tap Option again within the double-tap window → popover appears,
///   2. wait for it to focus its text field,
///   3. paste the prompt (reusing TextInjector's .privateState paste),
///   4. press Return to send.
enum ClaudeQuickEntry {
    /// Left Option key. (kVK_Option = 58; right Option = 61.)
    private static let optionKeyCode: CGKeyCode = 58
    /// Gap between the two taps — must be inside macOS's double-tap window (~300 ms).
    private static let doubleTapGapNanos: UInt64 = 120_000_000

    /// Simulate a single press+release of a modifier key. Modifier "key down" carries the
    /// flag; "key up" clears it — that's what produces the flagsChanged the OS/Claude sees.
    private static func tapOption(_ source: CGEventSource?) {
        if let down = CGEvent(keyboardEventSource: source, virtualKey: optionKeyCode, keyDown: true) {
            down.flags = .maskAlternate
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: optionKeyCode, keyDown: false) {
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    }

    /// Open the quick-entry popover (double-tap Option) and send `prompt` to it.
    @MainActor
    static func send(_ prompt: String, injector: TextInjector = TextInjector()) async {
        // 1. Double-tap Option to summon the popover.
        let source = CGEventSource(stateID: .privateState)
        tapOption(source)
        try? await Task.sleep(nanoseconds: doubleTapGapNanos)
        tapOption(source)

        // 2. Wait for the popover to appear and focus its input field.
        try? await Task.sleep(nanoseconds: 550_000_000)

        // 3. Paste the prompt, then 4. send.
        await injector.inject(prompt, fileURL: nil)
        try? await Task.sleep(nanoseconds: 250_000_000)
        await injector.pressReturn()
    }

    /// Sends a prompt and polls screen OCR (Option A) to extract Claude's response text.
    @MainActor
    static func sendAndReadResponse(_ prompt: String, injector: TextInjector = TextInjector()) async -> String {
        // Send the prompt
        await send(prompt, injector: injector)
        
        // Wait for generation to start and text to appear
        print("[CLAUDE-QUICK] Prompt sent. Waiting for generation to start...")
        try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds initial wait
        
        var lastText = ""
        var stableCount = 0
        let maxAttempts = 15
        
        print("[CLAUDE-QUICK] Starting Vision OCR polling for response...")
        
        for attempt in 1...maxAttempts {
            let currentOCR = CommandEngine.ocrScreen()
            
            // Check if ocr text has stopped changing
            if !currentOCR.isEmpty && currentOCR == lastText {
                stableCount += 1
                if stableCount >= 2 {
                    print("[CLAUDE-QUICK] OCR text stabilized after attempt \(attempt).")
                    break
                }
            } else {
                stableCount = 0
                if !currentOCR.isEmpty {
                    lastText = currentOCR
                }
            }
            
            try? await Task.sleep(nanoseconds: 1_500_000_000) // check every 1.5 seconds
        }
        
        // Extract the response lines
        return extractResponse(from: lastText, prompt: prompt)
    }
    
    private static func extractResponse(from ocrText: String, prompt: String) -> String {
        let lines = ocrText.components(separatedBy: .newlines)
        let cleanPrompt = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Match the prompt's first few words to find the starting line
        let firstFewWords = cleanPrompt.components(separatedBy: .whitespaces)
            .prefix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
        
        var foundPromptIndex = -1
        for (index, line) in lines.enumerated() {
            let lowerLine = line.lowercased()
            if lowerLine.contains(cleanPrompt) || (!firstFewWords.isEmpty && lowerLine.contains(firstFewWords)) {
                foundPromptIndex = index
                break
            }
        }
        
        if foundPromptIndex != -1 && foundPromptIndex < lines.count - 1 {
            let responseLines = lines[(foundPromptIndex + 1)...]
            let filtered = responseLines.filter { line in
                let l = line.lowercased()
                return !l.contains("quickly share") && !l.contains("double-tap") && !l.contains("claude.ai")
            }
            let response = filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !response.isEmpty {
                return response
            }
        }
        
        // Fallback: search for blocks below the first keyword match
        return ocrText
    }
}
