import Testing
@testable import BrowserCore

@Suite("Poses de Luciole")
struct LucioleStateTests {
    @Test("la pose suit l'état du panneau")
    func panelPose() {
        #expect(LucioleState.pose(availability: .ready, running: false, streaming: false, failed: false) == .idle)
        #expect(LucioleState.pose(availability: .ready, running: true, streaming: false, failed: false) == .think)
        #expect(LucioleState.pose(availability: .ready, running: true, streaming: true, failed: false) == .write)
        #expect(LucioleState.pose(availability: .ready, running: false, streaming: false, failed: true) == .err)
        #expect(LucioleState.pose(availability: .unreachable, running: false, streaming: false, failed: false) == .off)
        #expect(LucioleState.pose(availability: .connecting, running: false, streaming: false, failed: false) == .wake)
    }

    @Test("chaque événement réel de la tâche a sa pose")
    func eventPose() {
        #expect(LucioleState.pose(for: .thinking) == .think)
        #expect(LucioleState.pose(for: .waitingForProvider(seconds: 6)) == .wait)
        #expect(LucioleState.pose(for: .tool("search_web")) == .read)
        #expect(LucioleState.pose(for: .tool("read_page")) == .read)
        #expect(LucioleState.pose(for: .tool("fill_form")) == .write)
        #expect(LucioleState.pose(for: .tool("click")) == .act)
        #expect(LucioleState.pose(for: .tool("open_url")) == .act)
        #expect(LucioleState.pose(for: .tool("ask_user")) == .ask)
        #expect(LucioleState.pose(for: .finished(.done)) == .happy)
        #expect(LucioleState.pose(for: .finished(.failed("x"))) == .err)
        #expect(LucioleState.pose(for: .finished(.cancelled)) == .idle)
    }

    @Test("largeur du panneau bornée ; il pousse la page seulement si la fenêtre est assez large")
    func metrics() {
        #expect(AIPanelMetrics.clamp(100) == 320)
        #expect(AIPanelMetrics.clamp(900) == 520)
        #expect(AIPanelMetrics.clamp(400) == 400)
        #expect(AIPanelMetrics.pushesPage(windowWidth: 1200) && !AIPanelMetrics.pushesPage(windowWidth: 800))
    }
}
