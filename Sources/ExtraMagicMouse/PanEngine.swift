import CMultitouch
import Foundation

/// Turns raw Magic Mouse touch frames into held direction keys.
///
/// Frames arrive on a MultitouchSupport thread, scroll events on the main
/// thread and the watchdog on its own queue, so all state sits behind `lock`.
final class PanEngine {
    static let shared = PanEngine()

    /// Keys are released if no touch frame arrives for this long (device
    /// asleep, disconnected, or the framework stopped reporting).
    private static let frameTimeout = 0.25
    /// Smoothing factor for drag-mode velocity (0...1, higher = snappier).
    private static let velocitySmoothing: CGFloat = 0.35
    /// Drag mode measures speed, not distance, so its threshold is scaled up.
    private static let dragThresholdScale: CGFloat = 4
    /// A held key is released at this fraction of the press threshold, so it
    /// doesn't flicker when your finger sits right on the edge.
    private static let releaseHysteresis: CGFloat = 0.7
    /// Lift-off speed (surface widths per second) is measured over this window.
    private static let flickWindow = 0.06
    /// A lift faster than deadzone × this counts as a flick.
    private static let flickThresholdScale: CGFloat = 30
    /// Seconds of glide per unit of flick speed, before the length multiplier.
    private static let glidePerSpeed = 0.2
    private static let maxGlide = 3.0
    /// While slowing down, keys are pulsed with this period; the "on" share
    /// of each pulse shrinks to zero, which games see as decelerating.
    private static let pulsePeriod = 0.06
    /// A flick axis counts if it's at least this share of the speed, giving
    /// eight directions (diagonals within roughly ±22°).
    private static let diagonalShare: CGFloat = 0.38

    private let lock = NSLock()
    private let output = KeyOutput()
    private var settings = EngineSettings()
    private var appAllowed = false

    private var engaged = false
    private var origin = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var lastTimestamp = 0.0
    private var velocity = CGVector.zero
    private var held: Direction = []
    private var lastFrameUptime = 0.0
    private var lastEngagedUptime = -Double.infinity
    private var history: [(time: Double, point: CGPoint)] = []

    private let glideQueue = DispatchQueue(label: "extramagicmouse.glide")
    private var glideTimer: DispatchSourceTimer?
    private var glideDirection: Direction = []
    private var glideStart = 0.0
    private var glideDuration = 0.0
    private var gliding: Bool { glideTimer != nil }

    func update(settings newSettings: EngineSettings, appAllowed allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if newSettings != settings || allowed != appAllowed {
            // Release with the old key set before switching, so a change from
            // arrows to WASD can't strand a key.
            endGestureLocked()
        }
        settings = newSettings
        appAllowed = allowed
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        endGestureLocked()
    }

    func handleFrame(_ touches: UnsafePointer<MTTouch>?, count: Int, timestamp: Double) {
        lock.lock(); defer { lock.unlock() }
        lastFrameUptime = uptime()
        guard settings.enabled, appAllowed else {
            endGestureLocked()
            return
        }

        // A frame with no touches may come with a nil pointer; that's zero
        // fingers, not a reason to cancel a glide.
        var sumX: CGFloat = 0, sumY: CGFloat = 0, fingers = 0
        if let touches {
            for i in 0..<count {
                let touch = touches[i]
                guard touch.state == 4 || touch.state == 5 else { continue }
                sumX += CGFloat(touch.normalized.position.x)
                sumY += CGFloat(touch.normalized.position.y)
                fingers += 1
            }
        }
        if gliding {
            // Putting fingers back down catches the view, like a spinning globe.
            guard fingers >= settings.fingers else { return }
            stopGlideLocked()
        }
        guard fingers == settings.fingers else {
            if engaged { liftLocked() }
            return
        }

        let point = CGPoint(x: sumX / CGFloat(fingers), y: sumY / CGFloat(fingers))
        if !engaged {
            engaged = true
            origin = point
            lastPoint = point
            lastTimestamp = timestamp
            velocity = .zero
            history.removeAll()
        }
        lastEngagedUptime = uptime()
        history.append((timestamp, point))
        history.removeAll { timestamp - $0.time > Self.flickWindow * 2 }

        let vector: CGVector
        var threshold = CGFloat(settings.deadzone)
        switch settings.mode {
        case .joystick:
            vector = CGVector(dx: point.x - origin.x, dy: point.y - origin.y)
        case .drag:
            let dt = CGFloat(timestamp - lastTimestamp)
            if dt > 0 {
                let a = Self.velocitySmoothing
                velocity.dx += a * ((point.x - lastPoint.x) / dt - velocity.dx)
                velocity.dy += a * ((point.y - lastPoint.y) / dt - velocity.dy)
            }
            lastPoint = point
            lastTimestamp = timestamp
            vector = velocity
            threshold *= Self.dragThresholdScale
        }
        setHeldLocked(directions(for: vector, threshold: threshold))
    }

    /// Called every ~50 ms so a vanished device can never leave a key held.
    func watchdog() {
        lock.lock(); defer { lock.unlock() }
        // No frames arrive once fingers are off, so a glide ends on its own timer.
        guard !gliding else { return }
        if (engaged || !held.isEmpty) && uptime() - lastFrameUptime > Self.frameTimeout {
            endGestureLocked()
        }
    }

    /// Whether a continuous (touch-surface) scroll event should be swallowed,
    /// so the game doesn't also zoom or scroll while you pan.
    func shouldBlockScroll(momentum: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard settings.blockScroll, settings.enabled, appAllowed else { return false }
        if engaged || gliding { return true }
        let since = uptime() - lastEngagedUptime
        return momentum ? since < 3 : since < 0.3
    }

    private func directions(for v: CGVector, threshold: CGFloat) -> Direction {
        let dx = settings.invertX ? -v.dx : v.dx
        let dy = settings.invertY ? -v.dy : v.dy
        func limit(_ d: Direction) -> CGFloat {
            held.contains(d) ? threshold * Self.releaseHysteresis : threshold
        }
        var result: Direction = []
        if dx > limit(.right) { result.insert(.right) } else if dx < -limit(.left) { result.insert(.left) }
        if dy > limit(.up) { result.insert(.up) } else if dy < -limit(.down) { result.insert(.down) }
        return result
    }

    /// Fingers lifted mid-gesture: glide on if it was a flick, else stop.
    private func liftLocked() {
        let flick = flickVelocityLocked()
        endGestureLocked()
        guard settings.glide != .off, let flick else { return }
        let speed = hypot(flick.dx, flick.dy)
        guard speed >= CGFloat(settings.deadzone) * Self.flickThresholdScale else { return }
        let direction = flickDirection(flick, speed: speed)
        guard !direction.isEmpty else { return }
        let length = settings.glide.multiplier
        let duration = min(Double(speed) * Self.glidePerSpeed * length, Self.maxGlide * length)
        startGlideLocked(direction, duration: duration)
    }

    private func flickVelocityLocked() -> CGVector? {
        guard let last = history.last,
              let first = history.first(where: { last.time - $0.time <= Self.flickWindow })
        else { return nil }
        let dt = CGFloat(last.time - first.time)
        guard dt > 0.015 else { return nil }
        return CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
    }

    private func flickDirection(_ v: CGVector, speed: CGFloat) -> Direction {
        let dx = settings.invertX ? -v.dx : v.dx
        let dy = settings.invertY ? -v.dy : v.dy
        let minimum = speed * Self.diagonalShare
        var result: Direction = []
        if abs(dx) >= minimum { result.insert(dx > 0 ? .right : .left) }
        if abs(dy) >= minimum { result.insert(dy > 0 ? .up : .down) }
        return result
    }

    private func startGlideLocked(_ direction: Direction, duration: Double) {
        glideDirection = direction
        glideStart = uptime()
        glideDuration = duration
        let timer = DispatchSource.makeTimerSource(queue: glideQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.glideTick() }
        glideTimer = timer
        setHeldLocked(direction)
        timer.resume()
    }

    private func glideTick() {
        lock.lock(); defer { lock.unlock() }
        guard gliding else { return }
        let t = uptime() - glideStart
        guard t < glideDuration else {
            stopGlideLocked()
            return
        }
        guard settings.glideSlowsDown else { return }
        let duty = 1 - t / glideDuration
        let phase = t.truncatingRemainder(dividingBy: Self.pulsePeriod) / Self.pulsePeriod
        setHeldLocked(phase < duty ? glideDirection : [])
    }

    private func stopGlideLocked() {
        guard let timer = glideTimer else { return }
        timer.cancel()
        glideTimer = nil
        glideDirection = []
        setHeldLocked([])
    }

    private func endGestureLocked() {
        stopGlideLocked()
        if engaged {
            engaged = false
            lastEngagedUptime = uptime()
        }
        setHeldLocked([])
    }

    private func setHeldLocked(_ directions: Direction) {
        guard directions != held else { return }
        held = directions
        output.apply(directions, keys: settings.keys)
    }

    private func uptime() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

/// C callback handed to MultitouchSupport; it can't capture, so it goes
/// through the shared engine.
let multitouchCallback: MTContactCallbackFunction = { _, touches, count, timestamp, _ in
    PanEngine.shared.handleFrame(touches, count: Int(count), timestamp: timestamp)
    return 0
}
