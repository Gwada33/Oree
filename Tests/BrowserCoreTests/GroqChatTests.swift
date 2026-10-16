import Testing
import Foundation
@testable import BrowserCore

@Suite struct GroqChatTests {
    private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    @Test func requestCarriesToolsModelAndPromptButNoKey() throws {
        let body = try #require(try JSONSerialization.jsonObject(with: GroqChat.requestBody(prompt: "Bonjour", model: "openai/gpt-oss-20b")) as? [String: Any])
        #expect(body["model"] as? String == "openai/gpt-oss-20b")
        #expect(body["tool_choice"] as? String == "auto")
        #expect(body["reasoning_effort"] as? String == "low")
        let names = (body["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(names == AgentParser.tools)                        // exactement les outils du contrat, dans l'ordre
        #expect((body["messages"] as? [[String: Any]])?.last?["content"] as? String == "Bonjour")
        let other = try #require(try JSONSerialization.jsonObject(with: GroqChat.requestBody(prompt: "x", model: "llama-3.3-70b-versatile")) as? [String: Any])
        #expect(other["reasoning_effort"] == nil)
    }

    @Test func toolCallBecomesAnAgentLine() {
        let reply = GroqChat.parse(status: 200, body: json(["choices": [["message": ["tool_calls": [["function": ["name": "click", "arguments": "{\"ref\":\"@e3\"}"]]]]]]]))
        #expect(reply == .tool(name: "click", argumentsJSON: "{\"ref\":\"@e3\"}"))
        let line = GroqChat.agentText(reply)
        #expect(line == #"{"ref":"@e3","tool":"click"}"#)
        #expect(AgentParser.parse(line ?? "") == .call(AgentCall(name: "click", argumentsJSON: #"{"ref":"@e3"}"#)))
    }

    @Test func plainTextIsTheFinalAnswer() {
        let reply = GroqChat.parse(status: 200, body: json(["choices": [["message": ["content": "  Paris.  "]]]]))
        #expect(reply == .text("Paris."))
        #expect(AgentParser.parse(GroqChat.agentText(reply) ?? "") == .answer("Paris."))
    }

    @Test func errorsAreExplainedInFrench() {
        #expect(GroqChat.parse(status: 401, body: json(["error": ["message": "bad key"]])) == .failure(message: "Groq a refusé la clé (401). Vérifiez-la dans Réglages › Assistant IA.", retryAfter: nil))
        if case .failure(let message, let retry) = GroqChat.parse(status: 429, body: json(["error": ["message": "Rate limit reached"]]), retryAfterHeader: "12") {
            #expect(retry == 12 && message.contains("Rate limit reached"))
        } else { Issue.record("429 non reconnu") }
        if case .failure = GroqChat.parse(status: 200, body: Data("pas du json".utf8)) {} else { Issue.record("réponse illisible acceptée") }
        if case .failure = GroqChat.parse(status: 200, body: json(["choices": [["message": ["content": ""]]]])) {} else { Issue.record("réponse vide acceptée") }
    }

    @Test func severalToolCallsBecomeSeveralAgentLines() {
        let first: [String: Any] = ["function": ["name": "type", "arguments": "{\"ref\":\"@e1\",\"text\":\"a\"}"]]
        let second: [String: Any] = ["function": ["name": "click", "arguments": "{\"ref\":\"@e2\"}"]]
        let message: [String: Any] = ["tool_calls": [first, second]]
        let reply = GroqChat.parse(status: 200, body: json(["choices": [["message": message]]]))
        guard case .batch(let calls) = reply else { Issue.record("pas un lot"); return }
        #expect(calls.map(\.name) == ["type", "click"])
        #expect(AgentParser.parseAll(GroqChat.agentText(reply) ?? "").count == 2)
    }

    @Test func streamIsAssembledIncludingFragmentedToolCalls() {
        var text = ChatStreamAssembler()
        #expect(text.feed(line: "data: {\"choices\":[{\"delta\":{\"content\":\"Bon\"}}]}") == "Bon")
        #expect(text.feed(line: "") == nil && text.feed(line: ": keep-alive") == nil)
        #expect(text.feed(line: "data: {\"choices\":[{\"delta\":{\"content\":\"jour\"}}]}") == "jour")
        text.feed(line: "data: [DONE]")
        #expect(text.content == "Bonjour" && text.reply() == .text("Bonjour"))

        var tools = ChatStreamAssembler()
        tools.feed(line: "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"type\",\"arguments\":\"\"}}]}}]}")
        tools.feed(line: "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"ref\\\":\\\"@e1\\\"}\"}}]}}]}")
        tools.feed(line: "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"name\":\"click\",\"arguments\":\"{}\"}}]}}]}")
        #expect(tools.reply() == .batch([GroqChat.Call(name: "type", argumentsJSON: "{\"ref\":\"@e1\"}"), GroqChat.Call(name: "click", argumentsJSON: "{}")]))

        var failing = ChatStreamAssembler()
        failing.feed(line: "data: {\"error\":{\"message\":\"surcharge\"}}")
        #expect(failing.reply(provider: .lmstudio) == .failure(message: "LM Studio : surcharge", retryAfter: nil))
        #expect(ChatStreamAssembler().reply() == .failure(message: "Groq n'a rien répondu.", retryAfter: nil))
    }

    @Test func partialAnswerIsReadFromUnfinishedArguments() {
        #expect(ChatStreamAssembler.partialAnswer("{\"answer\":\"Bon") == "Bon")
        #expect(ChatStreamAssembler.partialAnswer("{\"answer\": \"Une \\\"citation\\\" et\\nune ligne") == "Une \"citation\" et\nune ligne")
        #expect(ChatStreamAssembler.partialAnswer("{\"answer\":\"caf\\u00e9\"}") == "café")
        #expect(ChatStreamAssembler.partialAnswer("{\"answer\":\"x\\u00") == "x")      // échappement incomplet : on attend la suite
        #expect(ChatStreamAssembler.partialAnswer("{\"ans") == nil && ChatStreamAssembler.partialAnswer("{\"answer\":") == nil)
        var stream = ChatStreamAssembler()
        stream.feed(line: "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"name\":\"done\",\"arguments\":\"{\\\"answer\\\":\\\"Bon\"}}]}}]}")
        #expect(stream.displayText == "Bon")
        stream.feed(line: "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"Je pense\"}}]}")
        #expect(stream.reasoning == "Je pense")
    }

    @Test func unreadableToolCallIsRecoveredOrRetried() {
        let recovered = GroqChat.parse(status: 400, body: json(["error": ["code": "tool_use_failed", "message": "Parsing failed", "failed_generation": "{\"name\":\"click\",\"arguments\":{\"ref\":\"@e2\"}}"]]))
        #expect(recovered == .tool(name: "click", argumentsJSON: "{\"ref\":\"@e2\"}"))
        #expect(GroqChat.parse(status: 400, body: json(["error": ["code": "tool_use_failed", "failed_generation": "du charabia"]])) == .failure(message: "Groq n'a pas su écrire l'appel d'outil.", retryAfter: 0.5))
    }

    @Test func providerDefaultsToGroqOnlyWhenAKeyExists() {
        #expect(AIProvider.effective(stored: nil, keys: [.groq]) == .groq)
        #expect(AIProvider.effective(stored: nil, keys: [.groq, .mistral]) == .mistral)      // Mistral d'abord
        #expect(AIProvider.effective(stored: nil, keys: []) == .groq)                 // sans clé : Groq, et le panneau demande sa clé
        #expect(AIProvider.effective(stored: .lmstudio, keys: [.groq]) == .lmstudio)  // le choix explicite l'emporte
        #expect(AIProvider(rawValue: "local") == nil)                                  // l'ancien choix « modèle intégré » n'existe plus : il se lit comme « pas de choix »
        #expect(AIProvider.mistral.endpoint.host == "api.mistral.ai" && AIProvider.mistral.defaultModel == "mistral-small-latest")
        #expect(AIProvider.mistral.keychainService == "com.nolhan.hyperbrowser.mistral")
        #expect(GroqChat.parse(status: 401, body: Data(), provider: .mistral) == .failure(message: "Mistral a refusé la clé (401). Vérifiez-la dans Réglages › Assistant IA.", retryAfter: nil))
    }

    @Test func requestSendsOnlyTheAllowedToolsAndTheOutputLimit() throws {
        let request = ModelRequest(messages: [ChatMessage(role: .system, content: "s"), ChatMessage(role: .user, content: "q")], tools: ["search_web"], maxTokens: 600)
        let body = try #require(try JSONSerialization.jsonObject(with: GroqChat.requestBody(request, model: "m", stream: true)) as? [String: Any])
        let names = (body["tools"] as? [[String: Any]] ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        #expect(Set(names) == ["search_web", "done"])                       // « done » est toujours permis : c'est la façon de répondre
        #expect(body["max_tokens"] as? Int == 600)
        #expect((body["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    @Test func toolCallsAndTheirResultsTravelAsTheProviderExpects() throws {
        let call = AgentCall(name: "click", argumentsJSON: "{\"ref\":\"@e3\"}")
        let request = ModelRequest(messages: [
            ChatMessage(role: .user, content: "q"),
            ChatMessage(role: .assistant, content: "", calls: [("call_1", call)]),
            ChatMessage(role: .tool, content: "<donnees>ok</donnees>", callID: "call_1"),
        ], tools: AgentParser.tools, maxTokens: 500)
        let body = try #require(try JSONSerialization.jsonObject(with: GroqChat.requestBody(request, model: "m")) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let assistant = messages[1]
        let function = ((assistant["tool_calls"] as? [[String: Any]])?.first?["function"]) as? [String: Any]
        #expect(function?["name"] as? String == "click" && function?["arguments"] as? String == "{\"ref\":\"@e3\"}")
        #expect((assistant["tool_calls"] as? [[String: Any]])?.first?["id"] as? String == "call_1")
        #expect(messages[2]["role"] as? String == "tool" && messages[2]["tool_call_id"] as? String == "call_1")
    }

    @Test func theStreamGivesTokensAndWhyItStopped() {
        var assembler = ChatStreamAssembler()
        assembler.feed(line: #"data: {"choices":[{"delta":{"content":"Bonj"}}]}"#)
        assembler.feed(line: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        assembler.feed(line: #"data: {"choices":[],"usage":{"prompt_tokens":812,"completion_tokens":40}}"#)
        #expect(assembler.usage?.prompt == 812 && assembler.usage?.completion == 40)
        #expect(assembler.wasCutShort)
    }
}
