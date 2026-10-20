import AppKit

/// "Press a key" prompt for assigning a custom key to a gesture.
enum KeyCapture {
    private static let modifierNames: [UInt16: String] = [
        56: "Shift", 60: "Right Shift", 59: "Control", 62: "Right Control",
        58: "Option", 61: "Right Option", 55: "Command", 54: "Right Command",
    ]

    private static let specialNames: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 117: "Forward Delete",
        115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Shows the prompt and returns the key pressed, or nil if cancelled.
    /// Fast Pan also accepts a modifier key on its own.
    static func run(for slot: GestureSlot) -> Action? {
        let modifierAlone = slot == .fastPan
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Press a key for \(slot.title)"
        alert.informativeText = modifierAlone
            ? "Press any key, or tap Shift, Control, Option or Command."
            : "Hold ⌃ ⌥ ⇧ ⌘ with it to make a combination, like ⌃1."
        alert.addButton(withTitle: "Cancel")

        var captured: Action?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard let result = KeyCapture.action(from: event, modifierAlone: modifierAlone) else { return event }
            captured = result
            NSApp.stopModal()
            return nil
        }
        alert.runModal()
        if let monitor { NSEvent.removeMonitor(monitor) }
        return captured
    }

    private static func action(from event: NSEvent, modifierAlone: Bool) -> Action? {
        if event.type == .flagsChanged {
            // Only the press of a lone modifier, not its release.
            guard modifierAlone, let name = modifierNames[event.keyCode],
                  !event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
            else { return nil }
            return .key(event.keyCode, name)
        }
        let held = event.modifierFlags.intersection([.control, .option, .shift, .command])
        var flags: CGEventFlags = []
        var prefix = ""
        if held.contains(.control) { flags.insert(.maskControl); prefix += "⌃" }
        if held.contains(.option) { flags.insert(.maskAlternate); prefix += "⌥" }
        if held.contains(.shift) { flags.insert(.maskShift); prefix += "⇧" }
        if held.contains(.command) { flags.insert(.maskCommand); prefix += "⌘" }
        return .key(event.keyCode, prefix + name(of: event), modifiers: flags)
    }

    private static func name(of event: NSEvent) -> String {
        if let name = specialNames[event.keyCode] { return name }
        if let chars = event.charactersIgnoringModifiers?.uppercased(),
           let scalar = chars.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
            return chars
        }
        return "Key \(event.keyCode)"
    }
}
