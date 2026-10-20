import Foundation

enum PanMode: String, Codable {
    /// Touch down, push in a direction, keys stay held until you return or lift.
    case joystick
    /// Keys are held only while your fingers are moving (like dragging the map).
    case drag
}

enum KeySet: String, Codable {
    case arrows
    case wasd
}

enum GlideLength: String, Codable {
    case off, short, medium, long

    var multiplier: Double {
        switch self {
        case .off: return 0
        case .short: return 0.5
        case .medium: return 1
        case .long: return 2
        }
    }
}

enum Scope: String, Codable {
    case listedApps
    case everywhere
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
    /// How long the view keeps moving after a flick.
    var glide = GlideLength.medium
    /// Pulse the keys so a glide decelerates instead of stopping dead.
    var glideSlowsDown = true

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
        glide = c.value(.glide, default: d.glide)
        glideSlowsDown = c.value(.glideSlowsDown, default: d.glideSlowsDown)
    }
}

struct Game: Codable, Equatable {
    var bundleID: String
    var name: String
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
