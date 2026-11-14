#if canImport(UIKit)
import UIKit

/// The SDK's own drawing over the host's screen (`show_on_page`'s pointer,
/// the field ring). The screen reader skips it; it never takes a touch.
class ClarityOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
}

/// Where the overlays go and how a target is brought on screen. Main thread.
enum OverlayHost {

    /// Clarity's accent when the chat did not send its own (`#4C71FE`).
    static let defaultAccent = UIColor(red: 0x4C / 255, green: 0x71 / 255, blue: 0xFE / 255, alpha: 1)

    static func color(hex: String?) -> UIColor? {
        guard let hex, hex.hasPrefix("#"), hex.count == 7, let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Adds the overlay to the host window, above the app and below the chat
    /// (the chat's presentation lives in the same window).
    static func insert(_ overlay: UIView, in window: UIWindow) {
        overlay.frame = window.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if let chat = WidgetHolder.presentedContainer?.view, chat.window === window,
           let branch = window.subviews.first(where: { chat.isDescendant(of: $0) }) {
            window.insertSubview(overlay, belowSubview: branch)
        } else {
            window.addSubview(overlay)
        }
    }

    /// The chat covers the whole screen: nothing of the app can be shown.
    static var chatCoversScreen: Bool {
        guard let chat = WidgetHolder.presentedContainer as? ClarityWidgetViewController else { return false }
        return chat.coversWholeScreen
    }

    static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Scrolls every scroll view the target is in so it lands in the upper
    /// part of the screen, clear of the chat's strip. Returns how far the
    /// target moved, in window points.
    @discardableResult
    static func scrollIntoView(_ node: ScreenNode, in window: UIWindow) -> CGFloat {
        let scrollViews: [UIScrollView]
        if let view = node.handle as? UIView {
            var chain: [UIScrollView] = []
            var current = view.superview
            while let parent = current {
                if let scroll = parent as? UIScrollView, scroll.isScrollEnabled, !(parent is UITextView) { chain.append(scroll) }
                current = parent.superview
            }
            scrollViews = chain
        } else {
            // An accessibility element (SwiftUI): the innermost scroll view
            // whose frame holds it.
            scrollViews = innermostScrollView(containing: node.rect, in: window).map { [$0] } ?? []
        }
        var moved: CGFloat = 0
        for scroll in scrollViews {
            let target = scroll.convert(node.rect.offsetBy(dx: 0, dy: -moved), from: window)
            let visibleHeight = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
            // Bring it near the top: a margin above, and room below so it is
            // not left at the bottom edge where the chat's strip sits.
            let margin = min(96, visibleHeight / 4)
            var desiredY = target.minY - scroll.adjustedContentInset.top - margin
            let maxY = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            desiredY = max(-scroll.adjustedContentInset.top, min(desiredY, max(maxY, -scroll.adjustedContentInset.top)))
            let visibleTop = scroll.contentOffset.y + scroll.adjustedContentInset.top
            let visibleBottom = scroll.contentOffset.y + scroll.bounds.height * 0.6
            guard target.minY < visibleTop || target.maxY > visibleBottom else { continue }
            let delta = desiredY - scroll.contentOffset.y
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: desiredY), animated: !reduceMotion)
            moved += delta
        }
        return moved
    }

    private static func innermostScrollView(containing rect: CGRect, in window: UIWindow) -> UIScrollView? {
        var best: UIScrollView?
        func visit(_ view: UIView) {
            guard !view.isHidden, !(view is ClarityOverlayView), view !== WidgetHolder.presentedContainer?.view else { return }
            if let scroll = view as? UIScrollView, !(view is UITextView), scroll.isScrollEnabled,
               scroll.convert(scroll.bounds, to: window).intersects(rect),
               scroll.convert(scroll.bounds, to: window).minX <= rect.midX,
               scroll.convert(scroll.bounds, to: window).maxX >= rect.midX {
                best = scroll
            }
            view.subviews.forEach(visit)
        }
        visit(window)
        return best
    }

    static func roundedPath(_ rect: CGRect, radius: CGFloat) -> UIBezierPath {
        UIBezierPath(roundedRect: rect, cornerRadius: radius)
    }
}

/// `show_on_page`: the screen dims around the target, a ring in the accent
/// colour, the agent's note next to it; the frame closes in from the whole
/// screen, breathes once, stays 5 s and fades. A touch anywhere hides it and
/// still reaches the app. Main thread.
final class PointerOverlay {

    static let padding: CGFloat = 6
    static let radius: CGFloat = 10
    static let dimColor = UIColor(red: 15 / 255, green: 18 / 255, blue: 30 / 255, alpha: 0.45)
    static let arriveSeconds: CFTimeInterval = 0.8
    static let breatheSeconds: CFTimeInterval = 1.4
    static let shownSeconds: TimeInterval = 5
    static let leaveSeconds: TimeInterval = 0.45

    private final class TouchThroughOverlay: ClarityOverlayView {
        var onTouch: (() -> Void)?
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if event?.type == .touches { onTouch?() }
            return nil
        }
    }

    private var overlay: TouchThroughOverlay?
    private var box: CGRect?
    private var generation = 0

    var isShown: Bool { overlay != nil }

    /// Draws the pointer around `rect` (window points) with `note`.
    func show(rect target: CGRect, note: String, accent: UIColor, in window: UIWindow) {
        let from = overlay != nil ? box : nil
        remove(instantly: true)
        generation += 1
        let current = generation
        let overlay = TouchThroughOverlay()
        overlay.onTouch = { [weak self] in
            DispatchQueue.main.async { self?.hide() }
        }
        OverlayHost.insert(overlay, in: window)
        let bounds = window.bounds
        let hole = target.insetBy(dx: -Self.padding, dy: -Self.padding)
        box = hole

        let dim = CAShapeLayer()
        dim.fillRule = .evenOdd
        dim.fillColor = Self.dimColor.cgColor
        dim.frame = bounds
        let ring = CAShapeLayer()
        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = accent.withAlphaComponent(0.45).cgColor
        ring.lineWidth = 4
        ring.frame = bounds
        overlay.layer.addSublayer(dim)
        overlay.layer.addSublayer(ring)

        let bubble = Self.noteBubble(note, accent: accent)
        let size = bubble.systemLayoutSizeFitting(
            CGSize(width: 280, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .defaultHigh, verticalFittingPriority: .fittingSizeLevel
        )
        let width = min(280, max(size.width, 60))
        let height = size.height
        var y = hole.maxY + 10
        if y + height > bounds.maxY - window.safeAreaInsets.bottom - 8 { y = hole.minY - 10 - height }
        y = max(window.safeAreaInsets.top + 8, y)
        let x = min(max(8, hole.minX), bounds.maxX - width - 8)
        bubble.frame = CGRect(x: x, y: y, width: width, height: height)
        overlay.addSubview(bubble)

        let finalDim = Self.dimPath(bounds: bounds, hole: hole)
        let finalRing = OverlayHost.roundedPath(hole, radius: Self.radius).cgPath
        dim.path = finalDim
        ring.path = finalRing
        if !OverlayHost.reduceMotion {
            let start = from ?? bounds
            let arrive = CABasicAnimation(keyPath: "path")
            arrive.fromValue = Self.dimPath(bounds: bounds, hole: start)
            arrive.toValue = finalDim
            arrive.duration = Self.arriveSeconds
            arrive.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            dim.add(arrive, forKey: "arrive")
            let ringArrive = CABasicAnimation(keyPath: "path")
            ringArrive.fromValue = OverlayHost.roundedPath(start, radius: Self.radius).cgPath
            ringArrive.toValue = finalRing
            ringArrive.duration = Self.arriveSeconds
            ringArrive.timingFunction = arrive.timingFunction
            ring.add(ringArrive, forKey: "arrive")
            if from == nil {
                let fadeIn = CABasicAnimation(keyPath: "opacity")
                fadeIn.fromValue = 0
                fadeIn.toValue = 1
                fadeIn.duration = Self.arriveSeconds / 2
                dim.add(fadeIn, forKey: "fade")
            }
            let breathe = CAKeyframeAnimation(keyPath: "lineWidth")
            breathe.values = [4, 9, 4]
            breathe.beginTime = CACurrentMediaTime() + Self.arriveSeconds
            breathe.duration = Self.breatheSeconds
            ring.add(breathe, forKey: "breathe")
            bubble.alpha = 0
            UIView.animate(withDuration: 0.3, delay: Self.arriveSeconds) { bubble.alpha = 1 }
        }
        self.overlay = overlay
        UIAccessibility.post(notification: .announcement, argument: note)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.shownSeconds) { [weak self] in
            guard let self, self.generation == current else { return }
            self.hide()
        }
    }

    /// Takes the pointer off the screen, with a short fade.
    func hide() {
        remove(instantly: false)
    }

    private func remove(instantly: Bool) {
        guard let overlay else { return }
        self.overlay = nil
        box = nil
        if instantly || OverlayHost.reduceMotion {
            overlay.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: Self.leaveSeconds, animations: { overlay.alpha = 0 }) { _ in
            overlay.removeFromSuperview()
        }
    }

    private static func dimPath(bounds: CGRect, hole: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(OverlayHost.roundedPath(hole, radius: radius))
        return path.cgPath
    }

    private static func noteBubble(_ note: String, accent: UIColor) -> UIView {
        let bubble = UIView()
        bubble.backgroundColor = .white
        bubble.layer.cornerRadius = 10
        bubble.layer.masksToBounds = true
        let border = UIView()
        border.backgroundColor = accent
        border.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = note
        label.numberOfLines = 0
        label.textColor = UIColor(red: 0.1, green: 0.1, blue: 0.14, alpha: 1)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(border)
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: bubble.topAnchor),
            border.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 3),
            label.topAnchor.constraint(equalTo: border.bottomAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -14),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 280 - 28),
        ])
        return bubble
    }
}

/// `focus_form_field`'s ring: tracks the field (a display link) until the
/// agent moves on, the field is filled, the screen goes away or 120 s pass.
/// Also the short flash after `fill_form_fields`. Main thread.
final class FieldRing {

    static let idleSeconds: TimeInterval = 120
    static let pulseSeconds: CFTimeInterval = 0.65
    static let flashSeconds: TimeInterval = 2.5

    private final class RingView: ClarityOverlayView {
        let shape = CAShapeLayer()
        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 4
            layer.addSublayer(shape)
        }
        required init?(coder: NSCoder) { nil }
    }

    private final class Held {
        let view: RingView
        weak var field: UIView?
        let started = Date()
        var link: CADisplayLink?
        let releaseWhenFilled: Bool
        init(view: RingView, field: UIView, releaseWhenFilled: Bool) {
            self.view = view
            self.field = field
            self.releaseWhenFilled = releaseWhenFilled
        }
    }

    private var held: Held?
    private var flashes: [Held] = []

    /// The field the agent is asking about, if any.
    var heldField: UIView? { held?.field }

    func hold(_ field: UIView, accent: UIColor, in window: UIWindow) {
        release()
        let wasFilled = (field as? UITextInput)?.hasText ?? false
        held = attach(field, accent: accent, in: window, releaseWhenFilled: !wasFilled, pulses: true)
    }

    func flash(_ field: UIView, accent: UIColor, in window: UIWindow) {
        let ring = attach(field, accent: accent, in: window, releaseWhenFilled: false, pulses: false)
        flashes.append(ring)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flashSeconds) { [weak self] in
            self?.drop(ring)
            self?.flashes.removeAll { $0 === ring }
        }
    }

    /// Lets go of the field being asked about.
    func release() {
        guard let held else { return }
        self.held = nil
        drop(held)
    }

    private func attach(_ field: UIView, accent: UIColor, in window: UIWindow, releaseWhenFilled: Bool, pulses: Bool) -> Held {
        let view = RingView()
        view.shape.strokeColor = accent.withAlphaComponent(0.45).cgColor
        OverlayHost.insert(view, in: window)
        let ring = Held(view: view, field: field, releaseWhenFilled: releaseWhenFilled)
        track(ring)
        if pulses && !OverlayHost.reduceMotion {
            let pulse = CAKeyframeAnimation(keyPath: "lineWidth")
            pulse.values = [4, 10, 4]
            pulse.duration = Self.pulseSeconds
            pulse.repeatCount = 2
            view.shape.add(pulse, forKey: "pulse")
        }
        let link = CADisplayLink(target: LinkTarget { [weak self, weak ring] in
            guard let self, let ring else { return }
            self.tick(ring)
        }, selector: #selector(LinkTarget.fire))
        link.add(to: .main, forMode: .common)
        ring.link = link
        return ring
    }

    private func tick(_ ring: Held) {
        guard let field = ring.field, field.window != nil, Date().timeIntervalSince(ring.started) < Self.idleSeconds else {
            if ring === held { release() } else { drop(ring) }
            return
        }
        if ring.releaseWhenFilled, ring === held, (field as? UITextInput)?.hasText == true {
            release()
            return
        }
        track(ring)
    }

    private func track(_ ring: Held) {
        guard let field = ring.field, let window = ring.view.window ?? field.window else { return }
        let rect = field.convert(field.bounds, to: window).insetBy(dx: -4, dy: -4)
        ring.view.shape.path = UIBezierPath(roundedRect: rect, cornerRadius: 8).cgPath
    }

    private func drop(_ ring: Held) {
        ring.link?.invalidate()
        ring.link = nil
        let view = ring.view
        UIView.animate(withDuration: 0.45, animations: { view.alpha = 0 }) { _ in view.removeFromSuperview() }
    }

    /// A display link holds its target strongly; this one holds the ring weakly.
    private final class LinkTarget: NSObject {
        let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc func fire() { body() }
    }
}
#endif
