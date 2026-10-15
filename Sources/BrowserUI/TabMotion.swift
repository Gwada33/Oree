import AppKit

/// The motion of tab rows: springs, like the system's own lists. A row that changes place does not jump: it starts where the eye last saw it
/// (`visualFrames`) and settles into its new slot (`reflow`). With reduced motion every spring becomes a plain, instant move.
@MainActor
enum TabMotion {
    /// Where each view is on screen right now: its frame plus whatever transform a drag or a running spring gives it.
    static func visualFrames(of views: [NSView]) -> [ObjectIdentifier: CGRect] {
        var frames: [ObjectIdentifier: CGRect] = [:]
        for view in views {
            let t = view.layer?.presentation()?.transform ?? view.layer?.transform ?? CATransform3DIdentity
            frames[ObjectIdentifier(view)] = view.frame.offsetBy(dx: t.m41, dy: t.m42)
        }
        return frames
    }

    /// Springs `view` from an offset to its place. Gentle, slightly under-damped: it settles with a small overshoot, like a drop in a system list.
    static func spring(_ view: NSView, fromX dx: CGFloat, fromY dy: CGFloat, stiffness: CGFloat = 320, damping: CGFloat = 26) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.removeAnimation(forKey: "oreeFlow")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
        guard !Motion.reduced, abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        let animation = CASpringAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(dx, dy, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.mass = 1; animation.stiffness = stiffness; animation.damping = damping
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "oreeFlow")
    }

    /// After the rows were rearranged and laid out: every row that is still there springs from where it was to where it is.
    static func reflow(_ views: [NSView], from before: [ObjectIdentifier: CGRect]) {
        for view in views {
            guard let old = before[ObjectIdentifier(view)] else { continue }
            spring(view, fromX: old.minX - view.frame.minX, fromY: old.minY - view.frame.minY)
        }
    }

    /// A row lifted by the pointer: a little bigger, with a soft shadow. Springs on the way up and on the way down.
    static func lift(_ view: NSView, _ lifted: Bool) {
        guard let layer = view.layer else { return }
        let target: Float = lifted ? 0.34 : 0
        if !Motion.reduced {
            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity; shadow.toValue = target; shadow.duration = 0.18
            layer.add(shadow, forKey: "oreeLiftShadow")
        }
        layer.shadowOpacity = target
    }
}
