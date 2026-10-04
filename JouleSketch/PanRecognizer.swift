import SwiftUI

/// Pans the view with the right mouse button. On iPad and iPhone it also
/// pans with two fingers on the screen or a trackpad, since touch screens
/// have no right button.
/// SwiftUI's own gestures can't tell mouse buttons apart, so this wraps
/// the platform's pan gesture recognizer.
struct PanRecognizer {
    enum Input {
        /// Dragging with the right (secondary) mouse button.
        case secondaryButton
        /// Dragging with two fingers on a touch screen, or scrolling with two
        /// fingers on a trackpad connected to an iPad.
        case twoFingers
    }

    let input: Input
    /// Called when panning starts, with where it started (local coordinates).
    var onBegan: (CGPoint) -> Void = { _ in }
    /// Called with the movement since the previous call, in points.
    let onChanged: (CGSize) -> Void
    /// Called when the drag ends or is cancelled.
    var onEnded: () -> Void = {}

    final class Coordinator: NSObject {
        var lastTranslation: CGPoint?
        /// Only pans with the right mouse button (iPad with a mouse or trackpad).
        var requiresSecondaryButton = false
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    /// Uses the recognizer's translation rather than its location, because
    /// trackpad scrolling moves the content without moving the pointer.
    private func handle(isBeginning: Bool, isActive: Bool, translation: CGPoint, location: CGPoint, coordinator: Coordinator) {
        if isBeginning {
            coordinator.lastTranslation = translation
            // Where the drag started: the pointer minus how far it has moved.
            onBegan(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
        } else if isActive, let last = coordinator.lastTranslation {
            onChanged(CGSize(width: translation.x - last.x, height: translation.y - last.y))
            coordinator.lastTranslation = translation
        } else if coordinator.lastTranslation != nil {
            coordinator.lastTranslation = nil
            onEnded()
        }
    }
}

/// A click with the right (secondary) mouse button, without dragging. On
/// iPad it's a secondary click with a mouse or trackpad.
struct SecondaryClickRecognizer {
    /// Called with where the click happened (local coordinates).
    let onClick: (CGPoint) -> Void
}

extension View {
    /// Adds the right-click recognizer where SwiftUI supports gesture
    /// recognizer representables.
    @ViewBuilder
    func secondaryClickGesture(_ recognizer: SecondaryClickRecognizer) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            gesture(recognizer)
        } else {
            self
        }
        #else
        if #available(iOS 18.0, *) {
            gesture(recognizer)
        } else {
            self
        }
        #endif
    }

    /// Adds the pan recognizer where SwiftUI supports gesture recognizer
    /// representables; older systems pan with the trackpad or pinch instead.
    @ViewBuilder
    func panGesture(_ recognizer: PanRecognizer) -> some View {
        #if os(macOS)
        if #available(macOS 26.0, *) {
            gesture(recognizer)
        } else {
            self
        }
        #else
        if #available(iOS 18.0, *) {
            gesture(recognizer)
        } else {
            self
        }
        #endif
    }

    #if os(macOS)
    /// Reports when ⌘ is pressed or released, on macOS 15 and later.
    @ViewBuilder
    func onCommandKeyChanged(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15.0, *) {
            onModifierKeysChanged(mask: .command) { _, keys in
                action(keys.contains(.command))
            }
        } else {
            self
        }
    }
    #endif
}

#if os(macOS)
import AppKit

extension PanRecognizer: NSGestureRecognizerRepresentable {
    func makeNSGestureRecognizer(context: Context) -> NSPanGestureRecognizer {
        let recognizer = NSPanGestureRecognizer()
        // Bit 1 is the right mouse button.
        recognizer.buttonMask = input == .secondaryButton ? 0x2 : 0x1
        return recognizer
    }

    func handleNSGestureRecognizerAction(_ recognizer: NSPanGestureRecognizer, context: Context) {
        handle(
            isBeginning: recognizer.state == .began,
            isActive: recognizer.state == .changed,
            translation: context.converter.translation(in: .local) ?? .zero,
            location: context.converter.location(in: .local),
            coordinator: context.coordinator
        )
    }
}

extension SecondaryClickRecognizer: NSGestureRecognizerRepresentable {
    func makeNSGestureRecognizer(context: Context) -> NSClickGestureRecognizer {
        let recognizer = NSClickGestureRecognizer()
        // Bit 1 is the right mouse button.
        recognizer.buttonMask = 0x2
        return recognizer
    }

    func handleNSGestureRecognizerAction(_ recognizer: NSClickGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onClick(context.converter.location(in: .local))
    }
}

/// Pans the view when scrolling with two fingers on a trackpad (or with a
/// scroll wheel). Sits invisibly behind the sheet and lets all clicks through.
struct ScrollWheelPanner: NSViewRepresentable {
    let onScroll: (CGSize) -> Void
    /// Points (top-left origin, in this view) where scrolling is left to the
    /// views on top, such as the tool palette.
    var passesThrough: (CGPoint) -> Bool = { _ in false }

    func makeNSView(context: Context) -> ScrollWheelView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        view.passesThrough = passesThrough
        return view
    }

    func updateNSView(_ view: ScrollWheelView, context: Context) {
        view.onScroll = onScroll
        view.passesThrough = passesThrough
    }

    final class ScrollWheelView: NSView {
        var onScroll: ((CGSize) -> Void)?
        var passesThrough: ((CGPoint) -> Bool)?
        private var monitor: Any?

        /// Clicks and drags go to the sheet, not to this view.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            // Scroll events go to the view under the pointer, which isn't this
            // one, so they're picked up with a monitor while over the sheet.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
                return handled ? nil : event
            }
        }

        /// Pans if the scroll happened over this view; returns whether it did.
        private func handleScroll(_ event: NSEvent) -> Bool {
            let point = convert(event.locationInWindow, from: nil)
            guard event.window === window, bounds.contains(point) else {
                return false
            }
            // Over the tool palette the scroll is left to it (it scrolls
            // sideways when it's wider than the window).
            let topLeft = CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y)
            if passesThrough?(topLeft) == true { return false }
            // Trackpads report points; mouse wheels report lines.
            let factor: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            onScroll?(CGSize(width: event.scrollingDeltaX * factor, height: event.scrollingDeltaY * factor))
            return true
        }
    }
}
#else
import UIKit

extension PanRecognizer: UIGestureRecognizerRepresentable {
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        switch input {
        case .secondaryButton:
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
            // Pan recognizers can't require a button, so the delegate checks it.
            context.coordinator.requiresSecondaryButton = true
            recognizer.delegate = context.coordinator
        case .twoFingers:
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.minimumNumberOfTouches = 2
            recognizer.maximumNumberOfTouches = 2
            // Also two-finger scrolling on a trackpad connected to the iPad.
            recognizer.allowedScrollTypesMask = .continuous
        }
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        handle(
            isBeginning: recognizer.state == .began,
            isActive: recognizer.state == .changed,
            translation: context.converter.translation(in: .local) ?? .zero,
            location: context.converter.location(in: .local),
            coordinator: context.coordinator
        )
    }
}

extension SecondaryClickRecognizer: UIGestureRecognizerRepresentable {
    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.buttonMaskRequired = .secondary
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onClick(context.converter.location(in: .local))
    }
}

extension PanRecognizer.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        !requiresSecondaryButton || gestureRecognizer.buttonMask.contains(.secondary)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
