import CoreGraphics

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
        }
    }
}

/// Holds synthetic keys down and lets them go, tracking exactly what it pressed
/// so nothing is ever left stuck.
final class KeyOutput {
    private static let arrowCodes: Set<CGKeyCode> = [123, 124, 125, 126]

    private let source = CGEventSource(stateID: .hidSystemState)
    private var pressed: Set<CGKeyCode> = []

    func apply(_ directions: Direction, keys: KeySet) {
        var wanted = Set<CGKeyCode>()
        for (direction, code) in keys.codes where directions.contains(direction) {
            wanted.insert(code)
        }
        for code in pressed.subtracting(wanted) { post(code, down: false) }
        for code in wanted.subtracting(pressed) { post(code, down: true) }
        pressed = wanted
    }

    private func post(_ code: CGKeyCode, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        if Self.arrowCodes.contains(code) {
            // Real arrow-key events carry these flags; some games check them.
            event.flags.formUnion([.maskNumericPad, .maskSecondaryFn])
        }
        event.post(tap: .cghidEventTap)
    }
}
