import CoreGraphics
import Foundation

struct Direction: OptionSet {
    let rawValue: UInt8
    static let up = Direction(rawValue: 1 << 0)
    static let down = Direction(rawValue: 1 << 1)
    static let left = Direction(rawValue: 1 << 2)
    static let right = Direction(rawValue: 1 << 3)
}

extension KeySet {
    var codes: [(Direction, CGKeyCode)] {
        switch self {
        case .arrows: return [(.up, 126), (.down, 125), (.left, 123), (.right, 124)]
        case .wasd: return [(.up, 13), (.down, 1), (.left, 0), (.right, 2)]
        case .middleMouse, .rightMouse: return []
        }
    }
}

/// Holds synthetic keys down and lets them go, tracking exactly what it pressed
/// so nothing is ever left stuck.
final class KeyOutput {
    private static let arrowCodes: Set<CGKeyCode> = [123, 124, 125, 126]
    static let modifierFlags: [CGKeyCode: CGEventFlags] = [
        56: .maskShift, 60: .maskShift, 59: .maskControl, 62: .maskControl,
        58: .maskAlternate, 61: .maskAlternate, 55: .maskCommand, 54: .maskCommand,
    ]

    static let source = CGEventSource(stateID: .hidSystemState)
    private var pressed: Set<CGKeyCode> = []

    private var heldModifiers: CGEventFlags {
        pressed.reduce(into: CGEventFlags()) { flags, code in
            if let flag = Self.modifierFlags[code] { flags.formUnion(flag) }
        }
    }

    /// Makes exactly `wanted` held: modifiers go down first and up last.
    func hold(_ wanted: Set<CGKeyCode>) {
        let isModifier = { (code: CGKeyCode) in Self.modifierFlags[code] != nil }
        let releases = pressed.subtracting(wanted).sorted { !isModifier($0) && isModifier($1) }
        let presses = wanted.subtracting(pressed).sorted { isModifier($0) && !isModifier($1) }
        for code in releases {
            pressed.remove(code)
            Self.post(code, down: false, flags: heldModifiers)
        }
        for code in presses {
            pressed.insert(code)
            Self.post(code, down: true, flags: heldModifiers)
        }
    }

    /// Posts one key event. Modifier keys are sent the way real ones are, as
    /// flags-changed events carrying the resulting modifier state.
    static func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if modifierFlags[code] != nil {
            event.type = .flagsChanged
            event.flags = flags
        } else {
            event.flags.formUnion(flags)
            if arrowCodes.contains(code) {
                // Real arrow-key events carry these flags; some games check them.
                event.flags.formUnion([.maskNumericPad, .maskSecondaryFn])
            }
        }
        event.post(tap: .cghidEventTap)
    }
}

/// Fires one-shot gesture actions.
enum ActionOutput {
    private static let queue = DispatchQueue(label: "extramagicmouse.actions")
    /// Games often read input once per frame, so a tap stays down this long.
    private static let pressDuration = 0.04

    static func perform(_ action: Action) {
        switch action.kind {
        case .none:
            break
        case .key:
            let code = CGKeyCode(action.keyCode)
            let flags = CGEventFlags(rawValue: action.modifiers)
            KeyOutput.post(code, down: true, flags: flags)
            queue.asyncAfter(deadline: .now() + pressDuration) {
                KeyOutput.post(code, down: false, flags: KeyOutput.modifierFlags[code] == nil ? flags : [])
            }
        case .middleClick:
            let location = CGEvent(source: nil)?.location ?? .zero
            postMiddle(.otherMouseDown, at: location)
            queue.asyncAfter(deadline: .now() + pressDuration) { postMiddle(.otherMouseUp, at: location) }
        case .scrollUp, .scrollDown:
            let lines: Int32 = action.kind == .scrollUp ? 3 : -3
            CGEvent(scrollWheelEvent2Source: KeyOutput.source, units: .line, wheelCount: 1,
                    wheel1: lines, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        }
    }

    private static func postMiddle(_ type: CGEventType, at location: CGPoint) {
        CGEvent(mouseEventSource: KeyOutput.source, mouseType: type,
                mouseCursorPosition: location, mouseButton: .center)?.post(tap: .cghidEventTap)
    }
}
