import Foundation

/// The FAQ card at the end of Settings: what Anthropic and Claude Code are,
/// what OpenAI and Codex are, and how a company, its models, a tool and a
/// session relate. The names come from the same tables the rest of the app
/// uses (`Providers`, `Tools`), so the text cannot drift from the buttons.
public enum FaqEntries {
    /// A tool, the company whose models it runs by default, and a sample id of
    /// one of those models. A test checks that `Providers.providerOf` agrees,
    /// so the sentence "X is a tool that runs Y's models" stays true to the code.
    /// opencode and others run models of many companies, so they have no pair.
    static let homeCompanies: [(tool: String, company: String, sampleModel: String)] = [
        ("claude_code", "anthropic", "claude-opus-5-5"),
        ("codex", "openai", "gpt-5"),
        ("gemini_cli", "google", "gemini-2.5-pro"),
    ]

    public struct Entry: Equatable {
        public var question: String
        public var answer: String
    }

    static func name(tool: String) -> String { Tools.toolNames[tool] ?? tool }
    static func name(company: String) -> String { Providers.providerNames[company] ?? company }

    public static var entries: [Entry] {
        let anthropic = name(company: "anthropic"), claudeCode = name(tool: "claude_code")
        let openAI = name(company: "openai"), codex = name(tool: "codex")
        return [
            Entry(question: "What is \(anthropic), and what is \(claudeCode)?",
                  answer: "\(anthropic) is the company. Claude is its family of models. \(claudeCode) is a tool that "
                      + "runs those models in a terminal or an editor. One chat open in a tool is a session."),
            Entry(question: "What is \(openAI), and what is \(codex)?",
                  answer: "\(openAI) is the company. GPT is its family of models. \(codex) is a tool that runs those "
                      + "models in a terminal or an editor. A company view adds up every model that company made, "
                      + "from every tool with data on this Mac."),
        ]
    }

    /// The card's items: each question as a heading, its answer wrapped as notes.
    public static func items() -> [Item] {
        entries.flatMap { [Item.heading($0.question)] + PanelModel.noteLines($0.answer) }
    }
}
