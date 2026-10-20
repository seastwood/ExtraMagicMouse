import CoreGraphics

/// An event tap that swallows Magic Mouse scrolling while you pan, so the
/// game doesn't zoom or scroll at the same time.
final class ScrollBlocker {
    static let shared = ScrollBlocker()

    fileprivate var tap: CFMachPort?

    var isInstalled: Bool { tap != nil }

    /// Needs Accessibility permission; returns quietly if it isn't granted yet.
    func installIfPossible() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << CGEventMask(CGEventType.scrollWheel.rawValue)
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
    // Only touch-surface scrolling is continuous; a wheel mouse passes through.
    guard type == .scrollWheel,
          event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
    else { return Unmanaged.passUnretained(event) }
    let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
    return PanEngine.shared.shouldBlockScroll(momentum: momentum) ? nil : Unmanaged.passUnretained(event)
}
