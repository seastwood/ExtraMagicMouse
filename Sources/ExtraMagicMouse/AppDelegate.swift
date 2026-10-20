import AppKit
import ApplicationServices
import CMultitouch
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private static let sensitivityPresets: [(String, Double)] = [
        ("High", 0.03), ("Medium", 0.05), ("Low", 0.08), ("Very Low", 0.12),
    ]

    private var statusItem: NSStatusItem!
    private var config = Config.load() {
        didSet {
            config.save()
            applyConfig()
        }
    }

    private var frontApp: Game?
    private var lastOtherApp: Game?
    private var multitouchAvailable = true
    private var activeDeviceCount = 0
    private var knownDeviceTotal = -1
    private var hotKeyRef: EventHotKeyRef?
    private var watchdog: DispatchSourceTimer?

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(appActivated(_:)),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake(_:)),
                              name: NSWorkspace.didWakeNotification, object: nil)
        if let app = NSWorkspace.shared.frontmostApplication { record(app) }

        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        ScrollBlocker.shared.installIfPossible()

        restartDevices()
        startWatchdog()
        registerHotKey()
        Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(periodicCheck),
                             userInfo: nil, repeats: true)
        applyConfig()
    }

    func applicationWillTerminate(_ notification: Notification) {
        PanEngine.shared.reset()
        EMMMultitouchStopAll()
    }

    // MARK: State

    private var appAllowed: Bool {
        guard let id = frontApp?.bundleID else { return false }
        return config.scope == .everywhere || config.games.contains { $0.bundleID == id }
    }

    private func applyConfig() {
        PanEngine.shared.update(settings: config.engine, appAllowed: appAllowed)
        updateIcon()
    }

    private func record(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return }
        let game = Game(bundleID: id, name: app.localizedName ?? id)
        frontApp = game
        lastOtherApp = game
    }

    private func restartDevices() {
        PanEngine.shared.reset()
        let started = Int(EMMMultitouchStartAll(multitouchCallback, config.includeBuiltInTrackpad))
        multitouchAvailable = started >= 0
        activeDeviceCount = max(started, 0)
        knownDeviceTotal = Int(EMMMultitouchDeviceCount())
    }

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "extramagicmouse.watchdog"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { PanEngine.shared.watchdog() }
        timer.resume()
        watchdog = timer
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = config.engine.enabled && appAllowed
        let image = NSImage(systemSymbolName: active ? "computermouse.fill" : "computermouse",
                            accessibilityDescription: "Extra Magic Mouse")
        image?.isTemplate = true
        button.image = image
        button.appearsDisabled = !config.engine.enabled
    }

    // MARK: Hot key (⌃⌥M toggles, so it works inside full-screen games)

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            Task { @MainActor in AppDelegate.shared?.toggleEnabled(nil) }
            return OSStatus(noErr)
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x454D_4D53), id: 1) // 'EMMS'
        RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    // MARK: Notifications & timers

    @objc private func appActivated(_ notification: Notification) {
        if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            record(app)
            applyConfig()
        }
    }

    @objc private func didWake(_ notification: Notification) {
        // Devices come back a moment after wake.
        perform(#selector(reconnect(_:)), with: nil, afterDelay: 2)
    }

    @objc private func periodicCheck() {
        if !ScrollBlocker.shared.isInstalled && AXIsProcessTrusted() {
            ScrollBlocker.shared.installIfPossible()
        }
        // The Magic Mouse turning on/off or reconnecting changes the device list.
        if multitouchAvailable && Int(EMMMultitouchDeviceCount()) != knownDeviceTotal {
            restartDevices()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let enabled = config.engine.enabled
        let status: String
        if !enabled {
            status = "Off"
        } else if appAllowed, let name = frontApp?.name {
            status = "Panning in \(name)"
        } else if let name = frontApp?.name {
            status = "Idle (\(name) isn't in your games)"
        } else {
            status = "Idle"
        }
        add(menu, "Extra Magic Mouse: \(status)", nil, enabled: false)
        add(menu, "Enabled", #selector(toggleEnabled(_:)), checked: enabled).keyEquivalentModifierMask = [.control, .option]
        menu.items.last?.keyEquivalent = "m"

        if !AXIsProcessTrusted() {
            add(menu, "⚠️ Grant Accessibility Permission…", #selector(openAccessibility(_:)))
        }
        if !multitouchAvailable {
            add(menu, "⚠️ Multitouch support unavailable on this macOS", nil, enabled: false)
        } else if activeDeviceCount == 0 {
            add(menu, "⚠️ No Magic Mouse found — is it on?", nil, enabled: false)
        } else {
            add(menu, "Touch devices: \(activeDeviceCount)", nil, enabled: false)
        }
        menu.addItem(.separator())

        // Games
        if let other = lastOtherApp, !config.games.contains(where: { $0.bundleID == other.bundleID }) {
            add(menu, "Add “\(other.name)” to Games", #selector(addLastApp(_:)))
        }
        let gamesMenu = NSMenu()
        add(gamesMenu, "Only in Games Listed Below", #selector(setScope(_:)),
            checked: config.scope == .listedApps, represented: Scope.listedApps.rawValue)
        add(gamesMenu, "Everywhere", #selector(setScope(_:)),
            checked: config.scope == .everywhere, represented: Scope.everywhere.rawValue)
        gamesMenu.addItem(.separator())
        if config.games.isEmpty {
            add(gamesMenu, "No games yet — switch to a game, then use “Add …”", nil, enabled: false)
        } else {
            add(gamesMenu, "Click a game to remove it:", nil, enabled: false)
            for game in config.games {
                add(gamesMenu, game.name, #selector(removeGame(_:)), checked: true, represented: game.bundleID)
            }
        }
        submenu(menu, "Games", gamesMenu)
        menu.addItem(.separator())

        // Behaviour
        let modeMenu = NSMenu()
        add(modeMenu, "Joystick — push and hold to keep panning", #selector(setMode(_:)),
            checked: config.engine.mode == .joystick, represented: PanMode.joystick.rawValue)
        add(modeMenu, "Drag — pan only while fingers move", #selector(setMode(_:)),
            checked: config.engine.mode == .drag, represented: PanMode.drag.rawValue)
        submenu(menu, "Mode", modeMenu)

        let fingersMenu = NSMenu()
        for n in 1...2 {
            add(fingersMenu, n == 1 ? "1 Finger" : "2 Fingers", #selector(setFingers(_:)),
                checked: config.engine.fingers == n, represented: n)
        }
        submenu(menu, "Fingers", fingersMenu)

        let sensitivityMenu = NSMenu()
        for (index, preset) in Self.sensitivityPresets.enumerated() {
            add(sensitivityMenu, preset.0, #selector(setSensitivity(_:)),
                checked: abs(config.engine.deadzone - preset.1) < 0.001, represented: index)
        }
        submenu(menu, "Sensitivity", sensitivityMenu)

        let glideMenu = NSMenu()
        for (title, glide) in [("Off", GlideLength.off), ("Short", .short), ("Medium", .medium), ("Long", .long)] {
            add(glideMenu, title, #selector(setGlide(_:)),
                checked: config.engine.glide == glide, represented: glide.rawValue)
        }
        glideMenu.addItem(.separator())
        add(glideMenu, "Flick and lift to glide; touch again to stop", nil, enabled: false)
        submenu(menu, "Flick Glide", glideMenu)

        let keysMenu = NSMenu()
        add(keysMenu, "Arrow Keys", #selector(setKeys(_:)),
            checked: config.engine.keys == .arrows, represented: KeySet.arrows.rawValue)
        add(keysMenu, "W A S D", #selector(setKeys(_:)),
            checked: config.engine.keys == .wasd, represented: KeySet.wasd.rawValue)
        submenu(menu, "Keys", keysMenu)

        add(menu, "Invert Left/Right", #selector(toggleInvertX(_:)), checked: config.engine.invertX)
        add(menu, "Invert Forward/Back", #selector(toggleInvertY(_:)), checked: config.engine.invertY)
        add(menu, "Block Scrolling While Panning", #selector(toggleBlockScroll(_:)),
            checked: config.engine.blockScroll)
        add(menu, "Use Built-in Trackpad Too", #selector(toggleBuiltIn(_:)),
            checked: config.includeBuiltInTrackpad)
        menu.addItem(.separator())

        add(menu, "Launch at Login", #selector(toggleLaunchAtLogin(_:)),
            checked: SMAppService.mainApp.status == .enabled)
        add(menu, "Reconnect Devices", #selector(reconnect(_:)))
        add(menu, "Quit Extra Magic Mouse", #selector(quit(_:)))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?, checked: Bool = false,
                     represented: Any? = nil, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = action == nil ? nil : self
        item.state = checked ? .on : .off
        item.representedObject = represented
        item.isEnabled = enabled && action != nil
        menu.addItem(item)
        return item
    }

    private func submenu(_ menu: NSMenu, _ title: String, _ sub: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    // MARK: Actions

    @objc func toggleEnabled(_ sender: Any?) {
        config.engine.enabled.toggle()
        NSSound(named: NSSound.Name(config.engine.enabled ? "Tink" : "Pop"))?.play()
    }

    @objc private func openAccessibility(_ sender: Any?) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func addLastApp(_ sender: Any?) {
        guard let app = lastOtherApp, !config.games.contains(where: { $0.bundleID == app.bundleID }) else { return }
        config.games.append(app)
    }

    @objc private func removeGame(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.games.removeAll { $0.bundleID == id }
    }

    @objc private func setScope(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let scope = Scope(rawValue: raw) { config.scope = scope }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = PanMode(rawValue: raw) { config.engine.mode = mode }
    }

    @objc private func setFingers(_ sender: NSMenuItem) {
        if let n = sender.representedObject as? Int { config.engine.fingers = n }
    }

    @objc private func setSensitivity(_ sender: NSMenuItem) {
        if let index = sender.representedObject as? Int { config.engine.deadzone = Self.sensitivityPresets[index].1 }
    }

    @objc private func setGlide(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let glide = GlideLength(rawValue: raw) { config.engine.glide = glide }
    }

    @objc private func setKeys(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let keys = KeySet(rawValue: raw) { config.engine.keys = keys }
    }

    @objc private func toggleInvertX(_ sender: Any?) { config.engine.invertX.toggle() }
    @objc private func toggleInvertY(_ sender: Any?) { config.engine.invertY.toggle() }
    @objc private func toggleBlockScroll(_ sender: Any?) { config.engine.blockScroll.toggle() }

    @objc private func toggleBuiltIn(_ sender: Any?) {
        config.includeBuiltInTrackpad.toggle()
        restartDevices()
    }

    @objc private func toggleLaunchAtLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nMove the app to /Applications and try again, or add it in System Settings → General → Login Items."
            alert.runModal()
        }
    }

    @objc private func reconnect(_ sender: Any?) { restartDevices() }

    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
