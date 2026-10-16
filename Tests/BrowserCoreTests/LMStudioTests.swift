import Testing
import Foundation
@testable import BrowserCore

@Suite struct LMStudioTests {
    @Test func baseAddressIsNormalized() {
        #expect(LMStudio.normalizedBase("").absoluteString == "http://localhost:1234/v1")
        #expect(LMStudio.normalizedBase("localhost:1234").absoluteString == "http://localhost:1234/v1")
        #expect(LMStudio.normalizedBase(" http://127.0.0.1:5000/ ").absoluteString == "http://127.0.0.1:5000/v1")
        #expect(LMStudio.normalizedBase("http://192.168.1.5:1234/v1/").absoluteString == "http://192.168.1.5:1234/v1")
        #expect(LMStudio.normalizedBase("::pas une adresse::").absoluteString == "http://localhost:1234/v1")
        #expect(LMStudio.chatURL(base: LMStudio.defaultBase).absoluteString == "http://localhost:1234/v1/chat/completions")
        #expect(LMStudio.modelsURL(base: LMStudio.defaultBase).absoluteString == "http://localhost:1234/v1/models")
    }

    @Test func modelListSkipsEmbeddingModels() {
        let data = Data(#"{"object":"list","data":[{"id":"qwen3-4b"},{"id":"text-embedding-nomic-embed-text-v1.5"},{"id":"openai/gpt-oss-20b"}]}"#.utf8)
        #expect(LMStudio.parseModels(data) == ["qwen3-4b", "openai/gpt-oss-20b"])
        #expect(LMStudio.parseModels(Data("pas du json".utf8)).isEmpty)
        #expect(LMStudio.parseModels(Data(#"{"data":[]}"#.utf8)).isEmpty)
    }

    @Test func loopbackIsRecognized() {
        #expect(LMStudio.isLoopback(URL(string: "http://localhost:1234/v1")!))
        #expect(LMStudio.isLoopback(URL(string: "http://127.0.0.1:1234/v1")!))
        #expect(LMStudio.isLoopback(URL(string: "http://[::1]:1234/v1")!))
        #expect(!LMStudio.isLoopback(URL(string: "http://192.168.1.5:1234/v1")!))
        #expect(!LMStudio.isLoopback(URL(string: "https://exemple.fr/v1")!))
    }

    @Test func modelChoiceKeepsThePreferredOneOnlyIfLoaded() {
        #expect(LMStudio.chooseModel(preferred: "a", available: ["a", "b"]) == "a")
        #expect(LMStudio.chooseModel(preferred: "z", available: ["a", "b"]) == "a")
        #expect(LMStudio.chooseModel(preferred: "", available: ["a"]) == "a")
        #expect(LMStudio.chooseModel(preferred: "x", available: []) == "x")
        #expect(LMStudio.chooseModel(preferred: "", available: []) == nil)
    }

    @Test func lmStudioIsLocalAndNeedsNoKey() {
        #expect(AIProvider.lmstudio.usesAPI && !AIProvider.lmstudio.isCloud)
        #expect(AIProvider.effective(stored: nil, keys: [.groq]) == .groq)       // jamais choisi tout seul
        #expect(AIProvider.mistral.isCloud)
    }
}
