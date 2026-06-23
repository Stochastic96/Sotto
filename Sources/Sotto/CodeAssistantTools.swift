import Foundation
import AppKit
#if canImport(FoundationModels)
import FoundationModels

// Coding-assistant tools for Jarvis. Each tool wraps a FoundationModels session
// tuned for precision (temperature 0.2) so on-device generation stays factual
// and deterministic. All prompts are kept short to respect the model's context
// window. Tools are registered in JarvisToolbox.all() / JarvisToolbox.routed(for:).

// MARK: - ExplainCodeTool

/// Ask the on-device model to explain a snippet of code in 2-3 sentences.
@available(macOS 26.0, *)
struct ExplainCodeTool: Tool {
    let name = "explain_code"
    let description = "Explain what a code snippet does in 2-3 concise sentences suitable for speaking aloud."

    @Generable
    struct Arguments {
        @Guide(description: "The source code to explain. Will be truncated to 1000 characters.")
        let code: String
        @Guide(description: "Programming language of the snippet, e.g. Swift, Python. Defaults to Swift if empty.")
        let language: String
    }

    func call(arguments: Arguments) async throws -> String {
        let lang = arguments.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Swift"
            : arguments.language.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(arguments.code.prefix(1000))
        let instructions = "You are a senior \(lang) developer. Explain this code concisely in 2-3 sentences. Focus on WHAT it does and WHY, not HOW line by line."
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: snippet,
                options: GenerationOptions(temperature: 0.2)
            )
            let explanation = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(explanation.prefix(200))
        } catch {
            return "Could not explain code: \(error.localizedDescription)"
        }
    }
}

// MARK: - GenerateGitCommitTool

@available(macOS 26.0, *)
@Generable
struct CommitMessage {
    @Guide(description: "A concise git commit message in the imperative mood, under 72 characters, no trailing period.")
    let message: String
}

/// Generate a git commit message from staged (or HEAD) diff output.
@available(macOS 26.0, *)
struct GenerateGitCommitTool: Tool {
    let name = "generate_git_commit"
    let description = "Generate a concise git commit message based on the staged diff of a project. Uses the configured workspace path when no path is supplied."

    @Generable
    struct Arguments {
        @Guide(description: "Absolute path to the git repository root. Leave empty to use the configured workspace path.")
        let projectPath: String
    }

    func call(arguments: Arguments) async throws -> String {
        let path = arguments.projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? SettingsController.workspacePath
            : arguments.projectPath.trimmingCharacters(in: .whitespacesAndNewlines)

        var diffSummary = CommandEngine.runCommandNatively("git -C \(path) diff --staged --stat")
        if diffSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diffSummary = CommandEngine.runCommandNatively("git -C \(path) diff --stat HEAD")
        }
        if diffSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No changes detected to generate a commit message for."
        }

        let instructions = "Generate a concise git commit message (imperative, < 72 chars, no period). Return ONLY the message."
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: diffSummary,
                generating: CommitMessage.self,
                options: GenerationOptions(temperature: 0.2)
            )
            return response.content.message.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Could not generate commit message: \(error.localizedDescription)"
        }
    }
}

// MARK: - FindBugTool

/// Ask the on-device model to identify the most critical bug in a code snippet.
@available(macOS 26.0, *)
struct FindBugTool: Tool {
    let name = "find_bug"
    let description = "Find the most critical bug or issue in a code snippet and suggest a fix. Returns a spoken-length result."

    @Generable
    struct Arguments {
        @Guide(description: "The source code to review for bugs. Will be truncated to 1000 characters.")
        let code: String
    }

    func call(arguments: Arguments) async throws -> String {
        let snippet = String(arguments.code.prefix(1000))
        let instructions = "You are a code reviewer. Find the most critical bug or issue in this code. Return: 1 sentence describing the bug and 1 sentence fix suggestion."
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: snippet,
                options: GenerationOptions(temperature: 0.2)
            )
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Could not analyse code: \(error.localizedDescription)"
        }
    }
}

// MARK: - ExplainErrorTool

@available(macOS 26.0, *)
@Generable
struct ErrorExplanation {
    @Guide(description: "Plain-English explanation of what caused the error.")
    let explanation: String
    @Guide(description: "The most likely fix for the error, in one sentence.")
    let fix: String
}

/// Translate a compiler or runtime error message into plain English with a fix suggestion.
@available(macOS 26.0, *)
struct ExplainErrorTool: Tool {
    let name = "explain_error"
    let description = "Explain a Swift or macOS error message in plain English and suggest the most likely fix. Returns a spoken-length result."

    @Generable
    struct Arguments {
        @Guide(description: "The error message or stack trace to explain.")
        let error: String
    }

    func call(arguments: Arguments) async throws -> String {
        let errorText = arguments.error.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = "You are a senior macOS/Swift developer. Explain this error in plain English and suggest the most likely fix. Be concise — 2 sentences max."
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(
                to: errorText,
                generating: ErrorExplanation.self,
                options: GenerationOptions(temperature: 0.2)
            )
            let explanation = response.content.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
            let fix = response.content.fix.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(explanation) Fix: \(fix)"
        } catch {
            return "Could not explain error: \(error.localizedDescription)"
        }
    }
}

#endif // canImport(FoundationModels)
