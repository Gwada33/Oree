import Testing
import Foundation
@testable import BrowserCore

@Suite struct ClaudeCodePromptTests {
    func request() -> ModelRequest {
        ModelRequest(messages: [ChatMessage(role: .system, content: "Tu es Luciole."),
                                ChatMessage(role: .user, content: "Clique sur Connexion"),
                                ChatMessage(role: .assistant, content: "", calls: [(id: "c1", call: AgentCall(name: "click", argumentsJSON: #"{"ref":"@e9"}"#))]),
                                ChatMessage(role: .tool, content: "Clic sur @e9 fait", callID: "c1")],
                     tools: ["click", "scroll", "done"], maxTokens: 800)
    }
    @Test func systemListsOnlyThePermittedTools() {
        let system = ClaudeCodePrompt.system(for: request())
        #expect(system.hasPrefix("Tu es Luciole.") && system.contains("- click(ref: texte)") && system.contains("- scroll(direction: up|down|top|bottom)") && system.contains("- done(answer: texte)"))
        #expect(system.contains(#"Exemple : {"tool":"scroll","direction":"bottom"}"#) && system.contains(#"Exemple : {"tool":"click","ref":"…"}"#))
        #expect(!system.contains("- fill_form") && !system.contains("- open_url"))
        #expect(system.contains("AUCUN outil à toi"))
    }
    @Test func conversationKeepsOrderAndMakesToolCallsReadableByTheParser() {
        let text = ClaudeCodePrompt.conversation(request())
        #expect(text.contains("Utilisateur :\nClique sur Connexion") && text.contains("Résultat de l'outil :\nClic sur @e9 fait") && text.hasSuffix("À toi, Luciole :"))
        // Les appels rendus doivent se relire avec le même analyseur que la réponse de Claude.
        let line = text.split(separator: "\n").first { $0.hasPrefix(#"{"tool":"click""#) }.map(String.init) ?? ""
        #expect(AgentParser.parse(line) == .call(AgentCall(name: "click", argumentsJSON: #"{"ref":"@e9"}"#)))
    }
    @Test func theCliOutputIsReadWithItsTokens() {
        let json = #"{"type":"result","is_error":false,"result":"Lisbonne.","usage":{"input_tokens":507,"cache_read_input_tokens":0,"output_tokens":103}}"#
        #expect(ClaudeCodePrompt.parse(output: "bruit avant " + json + "\n") == .init(text: "Lisbonne.", inputTokens: 507, outputTokens: 103, isError: false))
        #expect(ClaudeCodePrompt.parse(output: "pas du json") == nil)
    }
    @Test func locatorPrefersTheForcedPathThenCommonPlaces() {
        let only: (String) -> Bool = { $0 == "/opt/homebrew/bin/claude" }
        #expect(ClaudeCodeLocator.executable(environment: [:], home: "/Users/x", isExecutable: only)?.path == "/opt/homebrew/bin/claude")
        #expect(ClaudeCodeLocator.executable(environment: ["HB_CLAUDE_PATH": "/tmp/faux"], home: "/Users/x", isExecutable: { $0 == "/tmp/faux" })?.path == "/tmp/faux")
        #expect(ClaudeCodeLocator.executable(environment: ["PATH": "/a:/b"], home: "/Users/x", isExecutable: { $0 == "/b/claude" })?.path == "/b/claude")
        #expect(ClaudeCodeLocator.executable(environment: [:], home: "/Users/x", isExecutable: { _ in false }) == nil)
    }

    @Test func errorsGetAHumanMessage() {
        #expect(ClaudeCodePrompt.message(forError: "Not logged in · Please run /login").contains("/login"))
        #expect(ClaudeCodePrompt.message(forError: "Claude usage limit reached").contains("limite"))
    }
}
