import Foundation

/// One application-wide owner for reader display effects. Callers register
/// only visible readers in active scenes, and remove them on inactivity/removal.
/// Latest activated/changed brightness request wins independently per screen.
@MainActor
public final class ReaderDisplayCoordinator<Screen: Hashable> {
    private struct Request {
        let screen: Screen
        let keepAwake: Bool
        let brightness: Double?
    }
    private struct BrightnessState {
        var baseline: Double
        var applied: Double?
        var owner: UUID
        var requested: Double
    }
    private var requests: [UUID: Request] = [:]
    private var priority: [UUID] = []
    private var brightnessStates: [Screen: BrightnessState] = [:]
    private var supersededBySystem: [Screen: Set<UUID>] = [:]
    private var idleBaseline: Bool?
    private let readIdle: () -> Bool
    private let writeIdle: (Bool) -> Void
    private let readBrightness: (Screen) -> Double?
    private let writeBrightness: (Screen, Double) -> Void

    public init(readIdle: @escaping () -> Bool, writeIdle: @escaping (Bool) -> Void,
                readBrightness: @escaping (Screen) -> Double?,
                writeBrightness: @escaping (Screen, Double) -> Void) {
        self.readIdle = readIdle; self.writeIdle = writeIdle
        self.readBrightness = readBrightness; self.writeBrightness = writeBrightness
    }

    public func update(id: UUID, screen: Screen, keepAwake: Bool, brightness: Double?) {
        let brightness = brightness.map(ReaderSettings.normalizedBrightness)
        let old = requests[id]
        // Observe before inserting a new explicit request, so that the new
        // request can take ownership after an intervening system change.
        observeSystemBrightness(screen)
        if let old, old.screen != screen { observeSystemBrightness(old.screen) }
        if old == nil || old?.screen != screen || old?.brightness != brightness {
            priority.removeAll { $0 == id }; priority.append(id)
            supersededBySystem[screen]?.remove(id)
        }
        if let old, old.screen != screen { supersededBySystem[old.screen]?.remove(id) }
        requests[id] = Request(screen: screen, keepAwake: keepAwake, brightness: brightness)
        if let old, old.screen != screen { reconcileBrightness(old.screen) }
        reconcileBrightness(screen)
        reconcileIdle()
    }

    public func remove(id: UUID) {
        guard let old = requests.removeValue(forKey: id) else { return }
        supersededBySystem[old.screen]?.remove(id)
        priority.removeAll { $0 == id }
        reconcileBrightness(old.screen)
        reconcileIdle()
    }

    private func reconcileIdle() {
        if requests.values.contains(where: \.keepAwake) {
            if idleBaseline == nil {
                idleBaseline = readIdle()
                if !readIdle() { writeIdle(true) }
            }
        } else if let baseline = idleBaseline {
            // Preserve an external change made while the reader owned it.
            if readIdle(), !baseline { writeIdle(false) }
            idleBaseline = nil
        }
    }

    private func observeSystemBrightness(_ screen: Screen) {
        guard var state = brightnessStates[screen], let applied = state.applied,
              let current = readBrightness(screen), current.isFinite, (0...1).contains(current),
              abs(current - applied) > 0.000_001 else { return }
        state.baseline = current; state.applied = nil
        brightnessStates[screen] = state
        supersededBySystem[screen, default: []].formUnion(requests.compactMap { id, request in
            request.screen == screen && request.brightness != nil ? id : nil
        })
    }

    private func reconcileBrightness(_ screen: Screen) {
        observeSystemBrightness(screen)
        if supersededBySystem[screen]?.isEmpty == true { supersededBySystem.removeValue(forKey: screen) }
        guard let current = readBrightness(screen), current.isFinite, (0...1).contains(current) else {
            brightnessStates.removeValue(forKey: screen); return
        }
        let owner = priority.reversed().first { id in
            requests[id]?.screen == screen && requests[id]?.brightness != nil
                && supersededBySystem[screen]?.contains(id) != true
        }
        var state = brightnessStates[screen]
        if state?.applied == nil { state?.baseline = current }
        guard let owner, let requested = requests[owner]?.brightness else {
            if let state, state.applied != nil, current != state.baseline {
                writeBrightness(screen, state.baseline)
            }
            brightnessStates.removeValue(forKey: screen)
            return
        }
        if let state, state.owner == owner, state.requested == requested {
            brightnessStates[screen] = state; return
        }
        let baseline = state?.baseline ?? current
        if current != requested { writeBrightness(screen, requested) }
        let applied = readBrightness(screen).flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
        brightnessStates[screen] = .init(baseline: baseline, applied: applied, owner: owner, requested: requested)
    }
}
