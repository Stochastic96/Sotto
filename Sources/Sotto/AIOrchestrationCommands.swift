import Foundation

extension CommandEngine {
    static func processAIOrchestration(lowerText: String, text: String, selection: String?) async -> CommandOutput? {
        // --- 1. Selection-Aware Triggers ---
        if lowerText.hasPrefix("ask chatgpt about this selection") || lowerText.hasPrefix("ask chatgpt to explain this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain this selection:\n\(selectedStr)"
            openWebsite(urlStr: "https://chatgpt.com")
            return CommandOutput(text: prompt, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask claude about this selection") || lowerText.hasPrefix("ask claude to explain this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain this selection:\n\(selectedStr)"
            let response = await ClaudeQuickEntry.sendAndReadResponse(prompt)
            return CommandOutput(text: response, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("ask gemini about this selection") || lowerText.hasPrefix("ask gemini to explain this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain this selection:\n\(selectedStr)"
            openWebsite(urlStr: "https://gemini.google.com")
            return CommandOutput(text: prompt, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("explain this selection") || lowerText.hasPrefix("summarize this selection") {
            let selectedStr = selection ?? ""
            let prompt = "Explain or summarize this selection in detail:\n\n\(selectedStr)"
            return CommandOutput(
                text: prompt,
                pressReturnAfter: false,
                fileURL: nil,
                showLocalExplanation: true,
                explanationTitle: "Selection Summary"
            )
        }

        // --- 2. Screen-OCR Triggers ---
        if lowerText.hasPrefix("ask chatgpt about this screen") {
            let screenText = await performScreenOCR()
            let prompt = "Please explain/summarize this screen content:\n\(screenText)"
            openWebsite(urlStr: "https://chatgpt.com")
            return CommandOutput(text: prompt, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask claude about this screen") || lowerText.hasPrefix("explain this screen on claude") {
            let screenText = await performScreenOCR()
            let prompt = "Please explain/summarize this screen content:\n\(screenText)"
            let response = await ClaudeQuickEntry.sendAndReadResponse(prompt)
            return CommandOutput(text: response, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("explain this screen") || lowerText.hasPrefix("summarize this screen") {
            let screenText = await performScreenOCR()
            let prompt = "Summarize the text captured from my screen. Provide a clear, structured explanation of the key content:\n\n\(screenText)"
            return CommandOutput(
                text: prompt,
                pressReturnAfter: false,
                fileURL: nil,
                showLocalExplanation: true,
                explanationTitle: "Screen Summary"
            )
        }

        // --- 3. Chatbot Direct Questions ---
        if lowerText.hasPrefix("ask chatgpt ") {
            var question = String(text.dropFirst(12)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask ChatGPT '\(question)'")
            openWebsite(urlStr: "https://chatgpt.com")
            return CommandOutput(text: question, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask claude ") {
            var question = String(text.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask Claude Popover '\(question)'")
            let response = await ClaudeQuickEntry.sendAndReadResponse(question)
            return CommandOutput(text: response, pressReturnAfter: false, fileURL: nil)
        } else if lowerText.hasPrefix("ask gemini ") {
            var question = String(text.dropFirst(11)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask Gemini '\(question)'")
            openWebsite(urlStr: "https://gemini.google.com")
            return CommandOutput(text: question, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        } else if lowerText.hasPrefix("ask perplexity ") {
            var question = String(text.dropFirst(15)).trimmingCharacters(in: .whitespaces)
            while question.hasSuffix(".") || question.hasSuffix(",") || question.hasSuffix("?") || question.hasSuffix("!") { question.removeLast() }
            print("[ENGINE] Command recognized: Ask Perplexity '\(question)'")
            openWebsite(urlStr: "https://perplexity.ai")
            return CommandOutput(text: question, pressReturnAfter: true, fileURL: nil, delayBeforeInject: 2.0)
        }
        return nil
    }
}
