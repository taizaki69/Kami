import SwiftUI
import UIKit
import KamiCore

/// Shared by every window through AppModel. A screen remains available until
/// the portable coordinator has restored its last reader's captured state.
@MainActor
final class ReaderDisplayController {
    private var screens: [ObjectIdentifier: UIScreen] = [:]
    private var readers: [UUID: ObjectIdentifier] = [:]
    private lazy var effects = ReaderDisplayCoordinator<ObjectIdentifier>(
        readIdle: { UIApplication.shared.isIdleTimerDisabled },
        writeIdle: { UIApplication.shared.isIdleTimerDisabled = $0 },
        readBrightness: { [weak self] id in self?.screens[id].map { Double($0.brightness) } },
        writeBrightness: { [weak self] id, value in self?.screens[id]?.brightness = CGFloat(value) }
    )

    func update(id: UUID, screen: UIScreen, keepAwake: Bool, brightness: Double?) {
        let key = ObjectIdentifier(screen)
        screens[key] = screen
        readers[id] = key
        // UIKit documents hardware brightness only for the main display.
        // The target itself still comes from the reader's actual window.
        effects.update(id: id, screen: key, keepAwake: keepAwake,
                       brightness: screen === UIScreen.main ? brightness : nil)
        releaseUnusedScreens()
    }

    func remove(id: UUID) {
        effects.remove(id: id)
        readers.removeValue(forKey: id)
        releaseUnusedScreens()
    }

    private func releaseUnusedScreens() {
        let used = Set(readers.values)
        screens = screens.filter { used.contains($0.key) }
    }
}

/// Resolve the actual window's screen, never UIScreen.main. Window movement,
/// scene inactivity and dismantling all release the same stable reader ID.
@MainActor
struct ReaderDisplayEffects: UIViewRepresentable {
    let controller: ReaderDisplayController
    let active: Bool
    let keepAwake: Bool
    let brightness: Double?
    let onBrightnessAvailability: (Bool) -> Void

    func makeUIView(context: Context) -> ReaderDisplayAnchor { ReaderDisplayAnchor() }
    func updateUIView(_ view: ReaderDisplayAnchor, context: Context) {
        view.configure(controller: controller, active: active, keepAwake: keepAwake,
                       brightness: brightness, availability: onBrightnessAvailability)
    }
    static func dismantleUIView(_ view: ReaderDisplayAnchor, coordinator: ()) { view.release() }
}

@MainActor
final class ReaderDisplayAnchor: UIView {
    private let readerID = UUID()
    private var controller: ReaderDisplayController?
    private var active = false
    private var keepAwake = false
    private var brightness: Double?
    private var availability: ((Bool) -> Void)?
    private var lastAvailability: Bool?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(controller: ReaderDisplayController, active: Bool, keepAwake: Bool, brightness: Double?,
                   availability: @escaping (Bool) -> Void) {
        if self.controller !== controller { self.controller?.remove(id: readerID) }
        self.controller = controller
        self.active = active; self.keepAwake = keepAwake; self.brightness = brightness
        self.availability = availability
        synchronize()
    }

    override func didMoveToWindow() { super.didMoveToWindow(); synchronize() }

    func release() {
        controller?.remove(id: readerID)
        controller = nil; active = false; availability = nil
    }

    private func synchronize() {
        let supported = window?.windowScene?.screen === UIScreen.main
        if lastAvailability != supported {
            lastAvailability = supported
            // Avoid publishing SwiftUI state during updateUIView.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastAvailability == supported else { return }
                self.availability?(supported)
            }
        }
        guard active, let scene = window?.windowScene, scene.activationState == .foregroundActive else {
            controller?.remove(id: readerID); return
        }
        controller?.update(id: readerID, screen: scene.screen, keepAwake: keepAwake, brightness: brightness)
    }
}
