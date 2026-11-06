import Foundation

/// Where the collapsed call's bubble sits over the host app, in points of the
/// window. The customer drags it anywhere; let go, it sticks to the nearer
/// side, and stays clear of the system bars and the keyboard. Pure, so the
/// rules are tested without a device. Port of Android's `BubblePlacement.kt`.
struct BubblePlacement: Equatable {
    var left: Double
    var top: Double
    /// It sticks to the side text starts on (left, or right in a right-to-left
    /// layout): the page puts its aura on that side.
    var onStartSide: Bool

    /// The window, and what is not free of it.
    struct Area: Equatable {
        var width: Double
        var height: Double
        var barTop: Double
        var barBottom: Double
        var barLeft: Double
        var barRight: Double
        var keyboard: Double
        var margin: Double
        var rightToLeft: Bool

        var minTop: Double { barTop + margin }
        func maxTop(_ bubbleHeight: Double) -> Double {
            height - max(barBottom, keyboard) - margin - bubbleHeight
        }
        var minLeft: Double { barLeft + margin }
        func maxLeft(_ bubbleWidth: Double) -> Double { width - barRight - margin - bubbleWidth }
    }

    /// In a corner, before the customer moved it. The keyboard is left out:
    /// this is where the bubble belongs, and `clamped(to:)` lifts it above a
    /// keyboard only for as long as there is one.
    static func corner(
        _ area: Area, width: Double, height: Double, top: Bool, start: Bool
    ) -> BubblePlacement {
        var bare = area
        bare.keyboard = 0
        let onLeft = cornerOnLeft(start: start, rightToLeft: area.rightToLeft)
        return BubblePlacement(
            left: onLeft ? bare.minLeft : bare.maxLeft(width),
            top: top ? bare.minTop : bare.maxTop(height),
            onStartSide: start
        ).clamped(to: bare, width: width, height: height)
    }

    /// Whether a corner on the start side is on the screen's left, in this
    /// layout direction.
    static func cornerOnLeft(start: Bool, rightToLeft: Bool) -> Bool {
        start != rightToLeft
    }

    /// The screen edge it is against, for the page's `side`: the one it was
    /// placed on, whatever start and end mean elsewhere in the app.
    func onLeft(in area: Area) -> Bool {
        onStartSide != area.rightToLeft
    }

    /// Let go after a drag: to the side nearer the bubble's middle.
    static func dropped(
        _ area: Area, left: Double, top: Double, width: Double, height: Double
    ) -> BubblePlacement {
        let onLeft = left + width / 2 < area.width / 2
        return BubblePlacement(
            left: onLeft ? area.minLeft : area.maxLeft(width),
            top: top,
            onStartSide: onLeft != area.rightToLeft
        ).clamped(to: area, width: width, height: height)
    }

    /// Back inside the free area: the keyboard came up, or the bubble grew.
    func clamped(to area: Area, width: Double, height: Double) -> BubblePlacement {
        var copy = self
        copy.left = min(max(left, area.minLeft), max(area.minLeft, area.maxLeft(width)))
        copy.top = min(max(top, area.minTop), max(area.minTop, area.maxTop(height)))
        return copy
    }

    /// Against its side again: the bubble grew or shrank with its status.
    func stuckToSide(_ area: Area, width: Double, height: Double) -> BubblePlacement {
        var copy = self
        copy.left = onLeft(in: area) ? area.minLeft : area.maxLeft(width)
        return copy.clamped(to: area, width: width, height: height)
    }

    /// The spring's initial velocity for the flight from where the finger let
    /// go to its side, in flight-distances a second: the part of the throw
    /// that points at the target (none when it points away, or a flick back
    /// would launch it the wrong way at speed), capped at `max`.
    static func throwVelocity(
        velocityX: Double, velocityY: Double, toX dx: Double, _ dy: Double, max cap: Double
    ) -> Double {
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 1 else { return 0 }
        let toward = (velocityX * dx + velocityY * dy) / distance
        return min(max(0, toward) / distance, cap)
    }

    /// The same bubble moved by a finger, kept on the screen.
    func moved(by dx: Double, _ dy: Double, in area: Area, width: Double, height: Double) -> BubblePlacement {
        var copy = self
        copy.left += dx
        copy.top += dy
        return copy.clamped(to: area, width: width, height: height)
    }
}
