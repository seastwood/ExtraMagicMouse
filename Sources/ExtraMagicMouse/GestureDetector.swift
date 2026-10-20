import CoreGraphics

/// Recognises taps and pinches from touch frames. Not thread-safe: PanEngine
/// only calls it while holding its lock.
///
/// A tap is a group of fingers that land together, stay put and lift quickly.
/// Fingers already resting on the mouse aren't part of the group, so you can
/// tap with two fingers while another one rests.
struct GestureDetector {
    struct Contact {
        var id: Int32
        var point: CGPoint
    }

    private static let tapMaxDuration = 0.3
    /// Fingers of one tap must all land within this long of the first.
    private static let tapLandWindow = 0.15
    private static let tapMoveLimit: CGFloat = 0.04
    /// One-finger taps count only this close to the left or right edge.
    private static let edgeWidth: CGFloat = 0.25
    /// Change in finger spread (0...1 of the surface) per pinch step.
    private static let pinchStep: CGFloat = 0.08

    private struct Tap {
        var start: Double
        var down: Set<Int32> = []
        var size = 0
        var sumX: CGFloat = 0
    }

    private var startPoints: [Int32: CGPoint] = [:]
    private var tap: Tap?
    private var pinchPair: Set<Int32> = []
    private var pinchBase: CGFloat = 0
    private var pinchMid = CGPoint.zero
    private(set) var isPinching = false

    mutating func reset() {
        startPoints.removeAll()
        tap = nil
        pinchPair = []
        isPinching = false
    }

    /// A physical click means those fingers were clicking, not tapping.
    mutating func noteButtonPress() {
        tap = nil
    }

    mutating func process(_ contacts: [Contact], time: Double, pinchEnabled: Bool) -> [GestureSlot] {
        var events: [GestureSlot] = []
        var current: [Int32: CGPoint] = [:]
        for contact in contacts { current[contact.id] = contact.point }

        for (id, point) in current where startPoints[id] == nil {
            startPoints[id] = point
            if tap == nil || time - tap!.start > Self.tapLandWindow {
                // A late finger starts a fresh candidate; the old one wasn't a tap.
                tap = Tap(start: time)
            }
            tap!.down.insert(id)
            tap!.size += 1
            tap!.sumX += point.x
        }

        if var candidate = tap {
            let moved = candidate.down.contains { id in
                guard let p = current[id], let s = startPoints[id] else { return false }
                return hypot(p.x - s.x, p.y - s.y) > Self.tapMoveLimit
            }
            for id in candidate.down where current[id] == nil { candidate.down.remove(id) }
            if moved || time - candidate.start > Self.tapMaxDuration {
                tap = nil
            } else if candidate.down.isEmpty {
                tap = nil
                if let slot = slot(for: candidate) { events.append(slot) }
            } else {
                tap = candidate
            }
        }
        for id in startPoints.keys where current[id] == nil { startPoints[id] = nil }

        if pinchEnabled, contacts.count == 2 {
            let a = contacts[0].point, b = contacts[1].point
            let spread = hypot(a.x - b.x, a.y - b.y)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let pair: Set<Int32> = [contacts[0].id, contacts[1].id]
            if pair != pinchPair {
                pinchPair = pair
                pinchBase = spread
                pinchMid = mid
            } else {
                let change = spread - pinchBase
                let drift = hypot(mid.x - pinchMid.x, mid.y - pinchMid.y)
                // Spreading more than sliding: a pinch, not a two-finger pan.
                if abs(change) >= Self.pinchStep && abs(change) > drift {
                    events.append(change > 0 ? .pinchOut : .pinchIn)
                    pinchBase = spread
                    pinchMid = mid
                    isPinching = true
                    tap = nil
                }
            }
        } else {
            pinchPair = []
            isPinching = false
        }
        return events
    }

    private func slot(for tap: Tap) -> GestureSlot? {
        switch tap.size {
        case 2: return .twoFingerTap
        case 3: return .threeFingerTap
        case 1:
            let x = tap.sumX
            if x < Self.edgeWidth { return .leftEdgeTap }
            if x > 1 - Self.edgeWidth { return .rightEdgeTap }
            return nil
        default: return nil
        }
    }
}
