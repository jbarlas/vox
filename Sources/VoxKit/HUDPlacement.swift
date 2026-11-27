import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the HUD goes. Pure geometry in Cocoa screen coordinates (origin at
/// the bottom-left of the primary display, y up), so it can be tested without
/// real displays.
public enum HUDPlacement {
    public enum Edge: Equatable, Sendable {
        case top
        case bottom
    }

    /// The display the user is working on: the one under the pointer.
    ///
    /// `NSRect.contains` is half-open, so a pointer resting on a display's
    /// top edge — exactly where it sits after reaching for the menu bar on a
    /// secondary display — is "in" no screen at all, and naïve code falls back
    /// to `NSScreen.main` (the *key window's* screen), putting the HUD on the
    /// wrong display. Edges count as inside here, and a pointer outside every
    /// frame (mid-reconfiguration) picks the nearest one.
    public static func screenIndex(containing point: CGPoint, frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        if let index = frames.firstIndex(where: {
            point.x >= $0.minX && point.x <= $0.maxX && point.y >= $0.minY && point.y <= $0.maxY
        }) {
            return index
        }
        return frames.indices.min { distance(point, frames[$0]) < distance(point, frames[$1]) }
    }

    /// Top-centre under the menu bar by default; bottom-centre (above the
    /// Dock) when the top slot would sit on top of something the user is
    /// looking at — the pointer, or the text caret.
    public static func frame(
        size: CGSize,
        in visibleFrame: CGRect,
        avoiding obstacles: [CGRect],
        margin: CGFloat = 10,
        clearance: CGFloat = 24
    ) -> (frame: CGRect, edge: Edge) {
        let x = (visibleFrame.midX - size.width / 2).rounded()
        let top = CGRect(x: x, y: visibleFrame.maxY - size.height - margin, width: size.width, height: size.height)
        let bottom = CGRect(x: x, y: visibleFrame.minY + margin, width: size.width, height: size.height)
        let hits = { (candidate: CGRect) in
            obstacles.contains { candidate.insetBy(dx: -clearance, dy: -clearance).intersects($0) }
        }
        if hits(top) && !hits(bottom) { return (bottom, .bottom) }
        return (top, .top)
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Decides whether a fade-out's completion may still order the panel out.
///
/// The bug this exists for: `hide()` fades the panel and calls `orderOut`
/// from the animation's completion handler. A dictation started within that
/// fade (a press-and-hold tapped, released — which cancels — and pressed
/// again; or the next dictation right after a short one) called `show()`,
/// and then the *stale* completion ran and ordered the freshly shown panel
/// out. The HUD stayed hidden for that whole dictation. Each show and hide
/// takes a new token; a completion acts only if nothing happened since.
public struct PanelVisibility: Sendable, Equatable {
    public private(set) var isShown = false
    private var token = 0

    public init() {}

    public mutating func show() {
        token += 1
        isShown = true
    }

    /// Returns the token the fade-out's completion must present, or `nil`
    /// when there is nothing to hide.
    public mutating func hide() -> Int? {
        guard isShown else { return nil }
        isShown = false
        token += 1
        return token
    }

    public func shouldOrderOut(afterHide token: Int) -> Bool {
        !isShown && token == self.token
    }
}
