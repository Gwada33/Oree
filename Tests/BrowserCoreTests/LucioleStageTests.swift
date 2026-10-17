import Testing
import Foundation
@testable import BrowserCore

@Suite struct LucioleStageTests {
    @Test func closedMeansRestUnlessSomethingIsSelected() {
        #expect(LucioleStage.stage(for: .init()) == .rest)
        #expect(LucioleStage.stage(for: .init(hasSelection: true)) == .selection)
        #expect(LucioleStage.stage(for: .init(pageProtected: true, hasSelection: true)) == .rest)      // jamais d'éventail sur une page protégée
    }
    @Test func safetyStatesComeFirst() {
        #expect(LucioleStage.stage(for: .init(isOpen: true, running: true, actingOnPage: true, pendingConfirm: true)) == .validation)
        #expect(LucioleStage.stage(for: .init(isOpen: true, running: true, pendingQuestion: true)) == .question)
        #expect(LucioleStage.stage(for: .init(isOpen: true, pageProtected: true, pendingConfirm: true)) == .protected)
    }
    @Test func flowOfATask() {
        #expect(LucioleStage.stage(for: .init(isOpen: true)) == .call)
        #expect(LucioleStage.stage(for: .init(isOpen: true, running: true)) == .answer)
        #expect(LucioleStage.stage(for: .init(isOpen: true, running: true, actingOnPage: true)) == .action)
        #expect(LucioleStage.stage(for: .init(isOpen: true, hasAnswer: true)) == .answer)
    }
    @Test func everyStageHasItsPoseAndSize() {
        #expect(LucioleStage.rest.pose == .sleep && LucioleStage.call.pose == .idle && LucioleStage.validation.pose == .wait && LucioleStage.question.pose == .ask)
        #expect(LucioleStage.rest.mascotSize == 28 && LucioleStage.call.mascotSize == 54)
    }
}

@Suite struct LucioleGeometryTests {
    let page = CGSize(width: 1200, height: 800)
    @Test func capsuleIsCenteredAndBounded() {
        let wide = LucioleGeometry.capsule(in: page)
        #expect(wide.width == 620 && wide.midX == 600 && wide.maxY < 800 && wide.height == 66)
        #expect(LucioleGeometry.capsule(in: CGSize(width: 600, height: 700)).width == 420)         // 70 % d'une petite page
    }
    @Test func bubbleNeverCoversThePassage() {
        let passage = CGRect(x: 300, y: 300, width: 400, height: 40)
        for anchorX in stride(from: 40.0, through: 1100, by: 90) {
            let anchor = CGRect(x: anchorX, y: 300, width: 120, height: 40)
            let result = LucioleGeometry.bubble(height: 260, anchor: anchor, page: page, avoiding: LucioleGeometry.capsule(in: page))
            #expect(!result.frame.intersects(anchor), "x=\(anchorX) côté \(result.side)")
            #expect(result.frame.minX >= 0 && result.frame.maxX <= page.width && result.frame.minY >= 0)
        }
        _ = passage
    }
    @Test func withoutPassageTheBubbleSitsBottomRightAboveTheCapsule() {
        let capsule = LucioleGeometry.capsule(in: page)
        let result = LucioleGeometry.bubble(height: 300, anchor: nil, page: page, avoiding: capsule)
        #expect(result.side == .corner && result.frame.maxX <= page.width - 20 && result.frame.maxY <= capsule.minY)
    }
    @Test func fanOpensOnTheSideWithRoom() {
        let right = LucioleGeometry.fan(tip: CGPoint(x: 300, y: 400), count: 3, size: CGSize(width: 100, height: 34), page: page)
        let left = LucioleGeometry.fan(tip: CGPoint(x: 1150, y: 400), count: 3, size: CGSize(width: 100, height: 34), page: page)
        #expect(right.onRight && !left.onRight && right.frames.count == 3)
        #expect(right.frames[1].minY - right.frames[0].minY >= 34 && right.frames[2].minY - right.frames[1].minY >= 34)       // les gestes ne se chevauchent pas
        #expect((right.frames + left.frames).allSatisfy { $0.minX >= 0 && $0.maxX <= page.width })
    }
    @Test func theCardMovesAwayFromTextMediaAndButtons() {
        let capsule = LucioleGeometry.capsule(in: page)
        let size = CGSize(width: 380, height: 300)
        let spots = LucioleGeometry.bubbleSpots(size: size, page: page, capsule: capsule)
        #expect(spots.count == 6 && spots.allSatisfy { $0.minX >= 0 && $0.maxX <= page.width && $0.minY >= 0 })
        // Rien ne gêne : la place habituelle (au-dessus de la capsule, à gauche).
        #expect(LucioleGeometry.leastCovering(spots: spots, occupied: [], capsule: capsule) == 0)
        // Une vidéo occupe cette place : la carte va ailleurs, et ne couvre pas la vidéo.
        let video = LucioleGeometry.Occupied(rect: spots[0].insetBy(dx: 10, dy: 10), weight: 3)
        let index = LucioleGeometry.leastCovering(spots: spots, occupied: [video], capsule: capsule)
        #expect(index != 0 && spots[index].intersection(video.rect).isNull)
        // Du texte partout sauf à droite : elle va à droite.
        let text = (0..<30).map { LucioleGeometry.Occupied(rect: CGRect(x: 100, y: 60 + Double($0) * 22, width: 700, height: 20), weight: 1) }
        let chosen = LucioleGeometry.leastCovering(spots: spots, occupied: text, capsule: capsule)
        #expect(spots[chosen].minX > 700)
        #expect(spots.allSatisfy { LucioleGeometry.leastCovering(spots: [$0], occupied: [], capsule: capsule) == 0 })
    }

    @Test func suggestionsStackAboveTheCapsule() {
        let capsule = LucioleGeometry.capsule(in: page)
        let frames = LucioleGeometry.suggestions(widths: [200, 240, 180], above: capsule)
        #expect(frames.count == 3 && frames.allSatisfy { $0.maxY < capsule.minY } && frames[0].minY < frames[2].minY)
    }
}
