import CoreGraphics

/// An event tap that swallows Magic Mouse scrolling while you pan, so the
/// game doesn't zoom or scroll at the same time. It also watches for physical
/// clicks, so a click is never mistaken for a tap gesture.
final class ScrollBlocker {
    static let shared = ScrollBlocker()

    fileprivate var tap: CFMachPort?

    var isInstalled: Bool { tap != nil }

    /// Needs Accessibility permission; returns quietly if it isn't granted yet.
    func installIfPossible() {
        guard tap == nil else { return }
        let mask = [CGEventType.scrollWheel, .leftMouseDown, .rightMouseDown]
            .reduce(CGEventMask(0)) { $0 | CGEventMask(1) << CGEventMask($1.rawValue) }
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

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, _ in
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
