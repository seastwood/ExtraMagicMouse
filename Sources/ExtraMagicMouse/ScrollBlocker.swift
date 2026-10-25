import CMultitouch
import CoreGraphics
import os

/// An event tap that swallows Magic Mouse scrolling while you pan, so the
/// game doesn't zoom or scroll at the same time. It also watches for physical
/// clicks, so a click is never mistaken for a tap gesture, and can drop the
/// Magic Mouse's Mission Control gesture so it doesn't open mid-game (swiping
/// between full-screen apps and trackpad gestures still work).
final class ScrollBlocker {
    static let shared = ScrollBlocker()

    fileprivate var tap: CFMachPort?

    var isInstalled: Bool { tap != nil }

    /// Needs Accessibility permission; returns quietly if it isn't granted yet.
    func installIfPossible() {
        guard tap == nil else { return }
        let mask = [CGEventType.scrollWheel.rawValue, CGEventType.leftMouseDown.rawValue,
                    CGEventType.rightMouseDown.rawValue, dockControlEventType]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                           place: .headInsertEventTap,
                                           options: .defaultTap,
                                           eventsOfInterest: mask,
                                           callback: scrollTapCallback,
                                           userInfo: nil)
        else { return }
        tap = port
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }
}

/// The undocumented event type WindowServer uses to hand gestures such as
/// Mission Control to the Dock (NSEvent.EventType 30, "dock control").
private let dockControlEventType: UInt32 = 30

/// Undocumented dock-control fields, as used by tools that synthesise these
/// gestures: the HID gesture type (23 = dock swipe), the swipe's axis
/// (1 = horizontal, 2 = vertical) and its direction flag bits.
private let gestureHIDTypeField: UInt32 = 110
private let swipeMotionField: UInt32 = 123
private let swipeFlagBitsField: UInt32 = 135
private let dockSwipeHIDType: Int64 = 23

private let dockLog = Logger(subsystem: "com.seth.extramagicmouse", category: "dock")

/// A horizontal dock swipe is "swipe between full-screen apps"; that one is
/// left alone. Everything else (Mission Control, App Exposé…) is blocked.
private func isHorizontalDockSwipe(_ event: CGEvent) -> Bool {
    let hidType = EMMEventIntegerField(event, gestureHIDTypeField)
    let motion = EMMEventIntegerField(event, swipeMotionField)
    let flagBits = EMMEventIntegerField(event, swipeFlagBitsField)
    dockLog.debug("dock event hidType=\(hidType) motion=\(motion) flagBits=\(flagBits)")
    return hidType == dockSwipeHIDType && (motion == 1 || (motion == 0 && flagBits == 1))
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type.rawValue == dockControlEventType {
        let block = PanEngine.shared.shouldBlockDockGestures() && !isHorizontalDockSwipe(event)
        return block ? nil : Unmanaged.passUnretained(event)
    }
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = ScrollBlocker.shared.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseDown || type == .rightMouseDown {
        PanEngine.shared.noteButtonPress()
        return Unmanaged.passUnretained(event)
    }
    // Only touch-surface scrolling is continuous; a wheel mouse passes through.
    guard type == .scrollWheel,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    else { return Unmanaged.passUnretained(event) }
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
    return PanEngine.shared.shouldBlockScroll(momentum: momentum) ? nil : Unmanaged.passUnretained(event)
}
