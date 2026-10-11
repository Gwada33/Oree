import Testing
import Foundation
@testable import OreeAIEngine
import OreeAIProtocol

@Suite struct ControllerTests {
    private func make(_ model: FakeModel, engine: FakeEngine = FakeEngine(), idle: Duration = .seconds(30)) -> (AIController, FakeEngine, Events) {
        let events = Events()
        return (AIController(engine: engine, pin: model.pin, modelURL: model.url, idleDelay: idle, emit: { events.append($0) }), engine, events)
    }

    @Test func answersThenGoesWarm() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let (controller, engine, events) = make(model)
        #expect(await controller.status().state == .cold)
        #expect(await controller.run(AIRunRequest(taskID: "t1", userText: "Salut")))
        #expect(await events.waitFor { if case .done = $0 { true } else { false } })
        let deltas = events.list.compactMap { if case .textDelta(_, let text) = $0 { text } else { nil } }
        #expect(deltas.joined() == "Bonjour !")
        #expect(events.list.contains(.done(taskID: "t1", answer: "Bonjour !", sources: [])))
        #expect(await controller.status() == AIStatus(state: .warm, model: .ready))
        #expect(engine.calls == ["prewarm", "load", "startContext", "generate:Salut"])
    }

    @Test func missingModelIsReportedNotLoaded() async {
        let model = FakeModel(); defer { model.remove() }            // fichier jamais écrit
        let (controller, engine, events) = make(model)
        #expect(await controller.run(AIRunRequest(taskID: "t", userText: "?")) == false)
        #expect(await controller.status() == AIStatus(state: .cold, model: .missing))
        #expect(events.list.contains { if case .error = $0 { true } else { false } })
        #expect(engine.calls.isEmpty)
    }

    @Test func tamperedModelIsRefusedBeforeLoading() async {
        // même taille que l'original, un seul caractère changé : seule la somme SHA-256 peut le voir
        let model = FakeModel(); model.write("contenu du modèlX"); defer { model.remove() }
        #expect(Int64("contenu du modèlX".utf8.count) == model.pin.size)
        let (controller, engine, _) = make(model)
        #expect(await controller.warmUp() == AIStatus(state: .cold, model: .corrupt))
        #expect(engine.calls.isEmpty)
    }

    @Test func wrongSizeIsCorrupt() {
        let model = FakeModel(); model.write("trop court"); defer { model.remove() }
        #expect(ModelFile.verify(model.url, against: model.pin) == .corrupt)
    }

    @Test func idleBecomesTepidAndWarmUpComesBack() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let (controller, engine, _) = make(model, idle: .milliseconds(80))
        await controller.warmUp()
        #expect(await controller.status().state == .warm)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await controller.status().state == .tepid)
        #expect(engine.calls.contains("stopContext"))
        await controller.warmUp()
        #expect(await controller.status().state == .warm)
        #expect(engine.calls.filter { $0 == "load" }.count == 1)       // les poids n'ont pas été rechargés
    }

    @Test func criticalPressureGoesColdAndReloads() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let (controller, engine, _) = make(model)
        await controller.warmUp()
        await controller.memoryPressure(critical: false)
        #expect(await controller.status().state == .tepid)
        await controller.memoryPressure(critical: true)
        #expect(await controller.status().state == .cold)
        #expect(engine.calls.suffix(2) == ["stopContext", "unload"])
        await controller.warmUp()
        #expect(engine.calls.filter { $0 == "load" }.count == 2)
    }

    @Test func memoryPressureDoesNotKillARunningAnswer() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let engine = FakeEngine(); engine.delay = .milliseconds(60)
        let (controller, _, events) = make(model, engine: engine)
        await controller.run(AIRunRequest(taskID: "t", userText: "?"))
        await controller.memoryPressure(critical: true)                      // en pleine réponse
        #expect(await events.waitFor { if case .done(_, let answer, _) = $0 { answer == "Bonjour !" } else { false } })
        // la mémoire est rendue ensuite
        for _ in 0..<100 where await controller.status().state != .cold { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(await controller.status().state == .cold)
        #expect(engine.calls.suffix(2) == ["stopContext", "unload"])
    }

    @Test func cancelStopsTheTask() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let engine = FakeEngine(); engine.delay = .milliseconds(200)
        let (controller, _, events) = make(model, engine: engine)
        await controller.run(AIRunRequest(taskID: "t", userText: "long"))
        #expect(await events.waitFor { if case .textDelta = $0 { true } else { false } })
        await controller.cancel(taskID: "t")
        #expect(await events.waitFor { if case .error(_, let message) = $0 { message.contains("annulée") } else { false } })
        #expect(!events.list.contains { if case .done = $0 { true } else { false } })
        #expect(await controller.isBusy == false)
    }

    @Test func secondTaskIsRefusedWhileOneRuns() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let engine = FakeEngine(); engine.delay = .milliseconds(150)
        let (controller, _, _) = make(model, engine: engine)
        #expect(await controller.run(AIRunRequest(taskID: "a", userText: "1")))
        #expect(await controller.run(AIRunRequest(taskID: "b", userText: "2")) == false)
        await controller.cancel(taskID: "a")
    }

    @Test func engineFailureBecomesAnError() async {
        let model = FakeModel(); model.write(); defer { model.remove() }
        let engine = FakeEngine(); engine.failLoad = true
        let (controller, _, events) = make(model, engine: engine)
        #expect(await controller.run(AIRunRequest(taskID: "t", userText: "?")) == false)
        #expect(events.list.contains { if case .error(_, let m) = $0 { m.contains("refusé") } else { false } })
    }
}
