import CoreGraphics
import Foundation

enum PanMode: String, Codable {
    /// Touch down, push in a direction, keys stay held until you return or lift.
    case joystick
    /// Keys are held only while your fingers are moving (like dragging the map).
    case drag
}

/// What panning drives.
enum KeySet: String, Codable {
    case arrows
    case wasd
    /// Hold the middle mouse button and move the pointer (grab-the-map panning).
    case middleMouse
    /// Hold the right mouse button with the pointer offset by your push, for games
    /// that scroll toward the pointer while it's held (C&C Generals and friends).
    case rightMouse

    /// The mouse button this pans with by dragging, or nil for keys.
    var dragButton: CGMouseButton? {
        switch self {
        case .arrows, .wasd: return nil
        case .middleMouse: return .center
        case .rightMouse: return .right
        }
    }
}

enum Scope: String, Codable {
    case listedApps
    case everywhere
}

/// Something a gesture can do.
struct Action: Codable, Equatable {
    enum Kind: String, Codable {
        case none, key, middleClick, scrollUp, scrollDown
    }

    var kind: Kind
    var keyCode: UInt16 = 0
    /// CGEventFlags raw value held with the key (⌃⌥⇧⌘).
    var modifiers: UInt64 = 0
    var name: String

    static let none = Action(kind: .none, name: "None")
    static let middleClick = Action(kind: .middleClick, name: "Middle Click")
    static let scrollUp = Action(kind: .scrollUp, name: "Scroll Up")
    static let scrollDown = Action(kind: .scrollDown, name: "Scroll Down")

    static func key(_ code: UInt16, _ name: String, modifiers: CGEventFlags = []) -> Action {
        Action(kind: .key, keyCode: code, modifiers: modifiers.rawValue, name: name)
    }
}

/// Every gesture (plus the fast-pan key) that can be assigned an action.
enum GestureSlot: String, CaseIterable {
    case twoFingerTap, threeFingerTap, leftEdgeTap, rightEdgeTap, pinchIn, pinchOut, fastPan

    static let gestures: [GestureSlot] = [.twoFingerTap, .threeFingerTap, .leftEdgeTap, .rightEdgeTap, .pinchIn, .pinchOut]

    var title: String {
        switch self {
        case .twoFingerTap: return "Two-Finger Tap"
        case .threeFingerTap: return "Three-Finger Tap"
        case .leftEdgeTap: return "Left-Edge Tap"
        case .rightEdgeTap: return "Right-Edge Tap"
        case .pinchIn: return "Pinch In"
        case .pinchOut: return "Pinch Out"
        case .fastPan: return "Fast Pan"
        }
    }

    var defaultAction: Action {
        switch self {
        // Two-finger tap starts unassigned: briefly lifting your pan fingers
        // could otherwise fire it by accident.
        case .threeFingerTap: return .middleClick
        case .pinchIn: return .scrollDown
        case .pinchOut: return .scrollUp
        case .twoFingerTap, .leftEdgeTap, .rightEdgeTap, .fastPan: return .none
        }
    }

    /// The ready-made choices in the menu (any other key via "Custom Key…").
    var choices: [Action] {
        switch self {
        case .fastPan:
            return [.none, .key(56, "Shift"), .key(59, "Control"), .key(58, "Option"), .key(55, "Command")]
        default:
            return [.none, .middleClick, .key(49, "Space"), .key(48, "Tab"), .key(53, "Escape"),
                    .key(36, "Return"), .key(51, "Delete"), .key(115, "Home"), .scrollUp, .scrollDown]
        }
    }
}

/// Everything the touch engine needs; copied to it whenever it changes.
struct EngineSettings: Codable, Equatable {
    var enabled = true
    var mode = PanMode.joystick
    var fingers = 2
    /// How far (0...1 of the mouse surface) you must push before a key goes down.
    var deadzone = 0.05
    var keys = KeySet.arrows
    var invertX = false
    var invertY = false
    var blockScroll = true
    /// Drop the Dock's Mission Control gesture (two-finger double-tap) in games.
    var blockMissionControl = true
    /// Pointer speed multiplier for mouse-drag panning.
    var mousePanSpeed = 1.0
    /// Assigned actions by GestureSlot raw value; missing slots use their default.
    var gestures: [String: Action] = [:]

    func action(_ slot: GestureSlot) -> Action {
        gestures[slot.rawValue] ?? slot.defaultAction
    }

    mutating func setAction(_ action: Action, for slot: GestureSlot) {
        gestures[slot.rawValue] = action
    }

    init() {}

    // Decoded field by field so settings saved by an older version (missing
    // newer keys) keep everything they do have.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineSettings()
        enabled = c.value(.enabled, default: d.enabled)
        mode = c.value(.mode, default: d.mode)
        fingers = c.value(.fingers, default: d.fingers)
        deadzone = c.value(.deadzone, default: d.deadzone)
        keys = c.value(.keys, default: d.keys)
        invertX = c.value(.invertX, default: d.invertX)
        invertY = c.value(.invertY, default: d.invertY)
        blockScroll = c.value(.blockScroll, default: d.blockScroll)
        blockMissionControl = c.value(.blockMissionControl, default: d.blockMissionControl)
        mousePanSpeed = c.value(.mousePanSpeed, default: d.mousePanSpeed)
        gestures = c.value(.gestures, default: d.gestures)
    }
}

struct Game: Codable, Equatable {
    var bundleID: String
    var name: String
    /// This game's own settings; nil means it uses the defaults.
    var custom: EngineSettings? = nil
}

extension Game {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = c.value(.name, default: bundleID)
        custom = (try? c.decodeIfPresent(EngineSettings.self, forKey: .custom)) ?? nil
    }
}

struct Config: Codable {
    var engine = EngineSettings()
    var scope = Scope.listedApps
    var games: [Game] = []
    var includeBuiltInTrackpad = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        engine = c.value(.engine, default: d.engine)
        scope = c.value(.scope, default: d.scope)
        games = c.value(.games, default: d.games)
        includeBuiltInTrackpad = c.value(.includeBuiltInTrackpad, default: d.includeBuiltInTrackpad)
    }

    private static let defaultsKey = "ExtraMagicMouseConfig"

    static func load() -> Config {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return config
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

extension KeyedDecodingContainer {
    /// The stored value, or `fallback` if it's missing or unreadable.
    func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }
}
