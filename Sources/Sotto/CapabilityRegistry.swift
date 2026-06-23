import Foundation

// MARK: - CapabilityRegistry
//
// Every skill registers itself here at startup. The kernel queries the registry
// to find the cheapest capable path for any intent — deterministic first,
// Foundation Models second, MLX third, cloud last.
//
// This is the heart of the microkernel. It replaces hardcoded routing with
// self-describing capabilities that the planner can discover and compare.
//
// Usage:
//   // At skill definition time (or via @Skill macro):
//   CapabilityRegistry.shared.register(CapabilityDescriptor(
//       name: "open_app", keywords: ["open", "launch", "start", "app"],
//       latencyMs: 100, ramMB: 0, tier: .foundationModel, risk: .low
//   ))
//
//   // At routing time:
//   let best = await CapabilityRegistry.shared.cheapest(for: "open spotify")
//   // → CapabilityDescriptor(name: "open_app", tier: .foundationModel)

// MARK: - Types

enum AITier: Int, Comparable, Sendable, CustomStringConvertible {
    case reflex         = 0   // Pure Swift, 0 tokens, 0–20 ms
    case foundationModel = 1  // Apple Intelligence, on-device, 0 API cost, 200–600 ms
    case mlx            = 2   // On-device Qwen, local GPU, no network, 1–3 s
    case cloud          = 3   // External API (Claude CLI, etc.), requires network

    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    var description: String {
        switch self {
        case .reflex:          return "reflex"
        case .foundationModel: return "apple_intelligence"
        case .mlx:             return "mlx_qwen"
        case .cloud:           return "cloud"
        }
    }
}

enum RiskLevel: Int, Comparable, Sendable {
    case low = 0, medium = 1, high = 2
    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

struct CapabilityDescriptor: Sendable {
    let name: String
    let description: String
    let keywords: Set<String>      // used for routing — matched against user utterance words
    let latencyMs: Int             // estimated p50
    let ramMB: Int                 // 0 = negligible
    let tier: AITier
    let risk: RiskLevel
    let isResumable: Bool          // can the job be paused and resumed?
    let requiresNetwork: Bool

    init(
        name: String,
        description: String = "",
        keywords: Set<String>,
        latencyMs: Int,
        ramMB: Int = 0,
        tier: AITier,
        risk: RiskLevel = .low,
        isResumable: Bool = false,
        requiresNetwork: Bool = false
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.latencyMs = latencyMs
        self.ramMB = ramMB
        self.tier = tier
        self.risk = risk
        self.isResumable = isResumable
        self.requiresNetwork = requiresNetwork
    }
}

// MARK: - Registry actor

actor CapabilityRegistry {
    static let shared = CapabilityRegistry()
    private var capabilities: [String: CapabilityDescriptor] = [:]

    // MARK: - Registration

    func register(_ cap: CapabilityDescriptor) {
        capabilities[cap.name] = cap
        print("[REGISTRY] +\(cap.name) (\(cap.tier), \(cap.latencyMs)ms, keywords: \(cap.keywords.sorted().joined(separator: ",")))")
    }

    func registerAll(_ caps: [CapabilityDescriptor]) {
        for cap in caps { capabilities[cap.name] = cap }
        print("[REGISTRY] Registered \(caps.count) capabilities. Total: \(capabilities.count)")
    }

    // MARK: - Routing

    /// Returns the cheapest (lowest tier, then lowest latency) capability whose
    /// keywords overlap the intent words. Returns nil if nothing matches.
    func cheapest(for intent: String, maxTier: AITier = .cloud) -> CapabilityDescriptor? {
        let words = intentWords(intent)
        return capabilities.values
            .filter { cap in
                cap.tier <= maxTier && !cap.keywords.isDisjoint(with: words)
            }
            .sorted {
                if $0.tier != $1.tier { return $0.tier < $1.tier }
                return $0.latencyMs < $1.latencyMs
            }
            .first
    }

    /// All capabilities matching any of the given keywords, sorted cheapest first.
    func matching(keywords: Set<String>, maxTier: AITier = .cloud) -> [CapabilityDescriptor] {
        capabilities.values
            .filter { !$0.keywords.isDisjoint(with: keywords) && $0.tier <= maxTier }
            .sorted { $0.tier < $1.tier }
    }

    /// Every registered capability name, for the log console.
    func allNames() -> [String] {
        capabilities.keys.sorted()
    }

    func count() -> Int { capabilities.count }

    // MARK: - Private

    private func intentWords(_ text: String) -> Set<String> {
        Set(text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 })
    }
}

// MARK: - Seed: register all 33 existing tools at startup

extension CapabilityRegistry {

    /// Call once in AppController.start() after CoordinatorAgent is created.
    func seedBuiltins() async {
        let builtins: [CapabilityDescriptor] = [
            // ── Reflex tier (pure Swift, 0 tokens) ───────────────────────────
            .init(name: "win_maximize",      keywords: ["maximize","fullscreen","full","screen","window"],  latencyMs: 5,   tier: .reflex),
            .init(name: "win_minimize",      keywords: ["minimize","hide","window"],                        latencyMs: 5,   tier: .reflex),
            .init(name: "win_left",          keywords: ["tile","left","window"],                            latencyMs: 5,   tier: .reflex),
            .init(name: "win_right",         keywords: ["tile","right","window"],                           latencyMs: 5,   tier: .reflex),
            .init(name: "win_center",        keywords: ["center","window"],                                 latencyMs: 5,   tier: .reflex),
            .init(name: "media_play",        keywords: ["play","resume","music","spotify"],                 latencyMs: 5,   tier: .reflex),
            .init(name: "media_next",        keywords: ["next","skip","song","track"],                      latencyMs: 5,   tier: .reflex),
            .init(name: "media_prev",        keywords: ["previous","back","song","track"],                  latencyMs: 5,   tier: .reflex),
            .init(name: "mute",             keywords: ["mute","silence","volume"],                         latencyMs: 5,   tier: .reflex),
            .init(name: "volume_up",         keywords: ["volume","louder","up"],                            latencyMs: 5,   tier: .reflex),
            .init(name: "volume_down",       keywords: ["volume","softer","down","quiet"],                  latencyMs: 5,   tier: .reflex),
            .init(name: "brightness_up",     keywords: ["brightness","bright","screen"],                   latencyMs: 5,   tier: .reflex),
            .init(name: "brightness_down",   keywords: ["brightness","dim","dark","screen"],               latencyMs: 5,   tier: .reflex),
            .init(name: "dark_mode_toggle",  keywords: ["dark","light","mode","appearance"],               latencyMs: 10,  tier: .reflex),
            .init(name: "lock",             keywords: ["lock","screen"],                                   latencyMs: 5,   tier: .reflex),
            .init(name: "sleep",            keywords: ["sleep","mac"],                                     latencyMs: 5,   tier: .reflex),
            .init(name: "empty_trash",       keywords: ["empty","trash","bin"],                            latencyMs: 100, tier: .reflex, risk: .medium),

            // ── Spotlight tier (instant, 0 tokens, 0 AI) ──────────────────────
            .init(name: "spotlight_search_files", description: "Search files using Spotlight", keywords: ["search","find","file","document","where","locate","look"], latencyMs: 50, tier: .reflex, requiresNetwork: false),
            .init(name: "open_spotlight_result",  description: "Find and open a file by name",  keywords: ["open","find","file","document"],                           latencyMs: 100, tier: .reflex),

            // ── App launch is a pure NSWorkspace call — reflex tier, 0 tokens. ──
            // Low latency so the cheapest-path tiebreak picks it over the Spotlight
            // capability when an utterance like "open xcode" matches both.
            .init(name: "open_app",          keywords: ["open","launch","start","app","application"],       latencyMs: 80,  tier: .reflex),

            // ── Foundation Model tier (Apple Intelligence, on-device) ─────────
            .init(name: "open_website",      keywords: ["open","go","website","url","browse"],              latencyMs: 400, tier: .foundationModel, requiresNetwork: true),
            .init(name: "web_search",        keywords: ["search","google","find","look"],                   latencyMs: 400, tier: .foundationModel, requiresNetwork: true),
            .init(name: "control_spotify",   keywords: ["spotify","play","pause","song","artist","music"],  latencyMs: 400, tier: .foundationModel),
            .init(name: "set_volume",        keywords: ["volume","set","percent","mute","unmute"],          latencyMs: 400, tier: .foundationModel),
            .init(name: "adjust_brightness", keywords: ["brightness","brighter","dimmer"],                  latencyMs: 400, tier: .foundationModel),
            .init(name: "create_note",       keywords: ["note","create","save","write"],                    latencyMs: 400, tier: .foundationModel),
            .init(name: "create_reminder",   keywords: ["reminder","remind","task","todo"],                 latencyMs: 400, tier: .foundationModel),
            .init(name: "create_calendar_event", keywords: ["calendar","event","meeting","schedule"],       latencyMs: 400, tier: .foundationModel),
            .init(name: "run_shortcut",      keywords: ["shortcut","run","automation"],                     latencyMs: 500, tier: .foundationModel),
            .init(name: "wikipedia_lookup",  keywords: ["who","what","wikipedia","fact","about"],           latencyMs: 500, tier: .foundationModel, requiresNetwork: true),
            .init(name: "geocode_location",  keywords: ["where","location","map","place","city"],           latencyMs: 500, tier: .foundationModel, requiresNetwork: true),
            .init(name: "get_weather",       keywords: ["weather","temperature","forecast"],                latencyMs: 300, tier: .foundationModel, requiresNetwork: true),
            .init(name: "get_system_status", keywords: ["system","status","battery","wifi","disk"],         latencyMs: 200, tier: .foundationModel),
            .init(name: "get_ram_status",    keywords: ["ram","memory","usage"],                            latencyMs: 200, tier: .foundationModel),
            .init(name: "read_screen",       keywords: ["read","screen","see","show","what"],               latencyMs: 600, tier: .foundationModel),
            .init(name: "click_element",     keywords: ["click","press","tap","button"],                    latencyMs: 400, tier: .foundationModel),
            .init(name: "search_memory",     keywords: ["remember","recall","memory","said","mentioned"],   latencyMs: 300, tier: .foundationModel),
            .init(name: "manage_memory_goals", keywords: ["remember","goal","task","current","set"],        latencyMs: 300, tier: .foundationModel),
            .init(name: "draft_skill",       keywords: ["draft","skill","learn","automate"],                latencyMs: 800, tier: .foundationModel),
            .init(name: "run_skill",         keywords: ["run","execute","skill"],                           latencyMs: 200, tier: .foundationModel),
            .init(name: "ask_claude",        keywords: ["claude","ask","research","question"],              latencyMs: 2000, tier: .foundationModel, requiresNetwork: true),
            .init(name: "start_long_task",   keywords: ["all","bulk","every","inbox","email","clean"],      latencyMs: 1000, tier: .foundationModel, isResumable: true),

            // ── New tools (P1/P2 pipelines) ──────────────────────────────────
            .init(name: "morning_brief",       description: "Morning briefing",                          keywords: ["morning","brief","daily","today","wake","summary"],               latencyMs: 1500, tier: .foundationModel),
            .init(name: "start_focus_session", description: "Start a focus/DND session",                keywords: ["focus","session","dnd","distract","concentrate"],                  latencyMs: 800,  tier: .foundationModel),
            .init(name: "end_workday",         description: "End workday workflow",                      keywords: ["end","workday","day","done","finish","wrap"],                      latencyMs: 2000, tier: .foundationModel),
            .init(name: "switch_workspace",    description: "Switch workspace mode",                     keywords: ["workspace","switch","mode","development","writing","presentation"], latencyMs: 600,  tier: .foundationModel),
            .init(name: "organize_downloads",  description: "Organize downloads folder",                 keywords: ["organize","downloads","files","sort","clean"],                     latencyMs: 500,  tier: .reflex, risk: .medium),
            .init(name: "find_large_files",    description: "Find large files",                          keywords: ["large","files","storage","space","disk"],                         latencyMs: 300,  tier: .reflex),
            .init(name: "explain_code",        description: "Explain a code snippet",                    keywords: ["explain","code","snippet","what","does"],                         latencyMs: 800,  tier: .foundationModel),
            .init(name: "generate_git_commit", description: "Generate git commit message",               keywords: ["git","commit","message","changes","staged"],                      latencyMs: 1000, tier: .foundationModel),
            .init(name: "find_bug",            description: "Find bugs in code",                         keywords: ["bug","find","issue","problem","wrong"],                           latencyMs: 800,  tier: .foundationModel),
            .init(name: "explain_error",       description: "Explain a compiler or runtime error",       keywords: ["error","explain","why","crash","failed"],                         latencyMs: 800,  tier: .foundationModel),
            .init(name: "compose_workflow",    description: "Compose multi-step workflow",               keywords: ["compose","workflow","plan","setup","prepare","environment"],       latencyMs: 3000, tier: .foundationModel),

            // ── Previously undescribed tools (kept in sync by the drift guard in
            //    IntegrationTests.runCapabilityConsistencyCheck). NB: none of these may
            //    use the "open"/"launch" keywords or they'd out-compete open_app's reflex. ─
            .init(name: "recall_history",      description: "Recall what Jarvis recently did",                       keywords: ["history","recall","recent","did","you","earlier"],        latencyMs: 200, tier: .reflex),
            .init(name: "system_power_state",  description: "Lock, sleep, restart or shut down the Mac",             keywords: ["lock","sleep","restart","shutdown","power","logout"],     latencyMs: 50,  tier: .reflex, risk: .medium),
            .init(name: "network_diagnostics", description: "Check Wi-Fi / internet connectivity",                   keywords: ["wifi","wi-fi","internet","connection","reachable","ping","online"], latencyMs: 200, tier: .reflex),
            .init(name: "manage_clipboard",    description: "Read or write the clipboard",                           keywords: ["clipboard","copy","paste","copied","pasteboard"],         latencyMs: 20,  tier: .reflex),
            .init(name: "manage_apps_windows", description: "Switch, activate, list, or arrange app windows",        keywords: ["window","switch","activate","foreground","minimize","focus","tile"], latencyMs: 50, tier: .reflex),
            .init(name: "simulate_keystroke",  description: "Send a keyboard shortcut or keystroke",                 keywords: ["keystroke","press","hotkey","key","shortcut"],            latencyMs: 30,  tier: .reflex),

            // ── MLX tier (on-device Qwen, no network needed) ─────────────────
            .init(name: "scripting_executor", keywords: ["script","code","generate","swift","compute"],    latencyMs: 3000, ramMB: 1500, tier: .mlx),
        ]
        registerAll(builtins)
    }
}
