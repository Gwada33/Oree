import CoreGraphics
import Testing
@testable import BrowserCore

@Suite("Gestes de souris")
struct MouseGestureTests {
    /// Une trace qui va de segment en segment : (dx, dy) cumulés à partir de (200, 200), plusieurs points par segment.
    private func trail(_ moves: [(CGFloat, CGFloat)]) -> [CGPoint] {
        var points = [CGPoint(x: 200, y: 200)]
        for (dx, dy) in moves { let last = points.last!; for step in 1...5 { points.append(CGPoint(x: last.x + dx * CGFloat(step) / 5, y: last.y + dy * CGFloat(step) / 5)) } }
        return points
    }

    @Test("les quatre directions")
    func directions() {
        #expect(MouseGesture.recognize(trail([(-120, 0)])).code == "L")
        #expect(MouseGesture.recognize(trail([(120, 0)])).code == "R")
        #expect(MouseGesture.recognize(trail([(0, 120)])).code == "U")        // y croît vers le haut
        #expect(MouseGesture.recognize(trail([(0, -120)])).code == "D")
    }

    @Test("une suite de directions, sans répétition d'une même direction")
    func sequences() {
        #expect(MouseGesture.recognize(trail([(0, -100), (100, 0)])).code == "DR")
        #expect(MouseGesture.recognize(trail([(0, 100), (0, -100)])).code == "UD")
        #expect(MouseGesture.recognize(trail([(100, 0), (100, 0), (0, 80)])).code == "RU")
        #expect(MouseGesture.recognize(trail([(-80, 0), (0, -80), (80, 0), (0, 80), (-80, 0)])).code.count == 4)        // au plus quatre directions
    }

    @Test("un trait diagonal prend l'axe dominant ; un tremblement ne fait pas un geste ; un simple clic droit reste un clic")
    func tolerance() {
        #expect(MouseGesture.recognize(trail([(100, 40)])).code == "R")
        #expect(MouseGesture.recognize(trail([(30, -100)])).code == "D")
        let jitter = [CGPoint(x: 200, y: 200), CGPoint(x: 204, y: 198), CGPoint(x: 199, y: 203), CGPoint(x: 205, y: 201)]
        #expect(!MouseGesture.recognize(jitter).isGesture && MouseGesture.recognize(jitter).code.isEmpty)
        #expect(!MouseGesture.recognize([]).isGesture && !MouseGesture.recognize([CGPoint(x: 1, y: 1)]).isGesture)
        let small = MouseGesture.recognize(trail([(18, 0)]))
        #expect(small.isGesture && small.code.isEmpty)               // assez bougé pour ne pas ouvrir le menu, pas assez pour un geste
    }

    @Test("chaque geste a une action, sans doublon, et les plus courants sont les plus courts")
    func bindings() {
        #expect(Set(MouseGesture.bindings.values).count == MouseGesture.bindings.count)
        #expect(MouseGesture.action(for: "L") == .back && MouseGesture.action(for: "R") == .forward && MouseGesture.action(for: "DR") == .closeTab && MouseGesture.action(for: "XYZ") == nil)
        #expect(MouseGesture.Action.allCases.allSatisfy { !$0.label.isEmpty })
        #expect(MouseGesture.bindings.keys.allSatisfy { $0.count <= 2 && $0.allSatisfy { "LRUD".contains($0) } })
    }
}
