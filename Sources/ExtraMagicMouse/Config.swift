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
