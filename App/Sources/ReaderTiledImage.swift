import SwiftUI
import UIKit
import QuartzCore
import KamiCore

/// CATiledLayer requests only the drawing regions it needs. The decoded source
/// remains a bounded whole bitmap; no region-decoder or global memory ceiling
/// is implied. Each draw reads an immutable snapshot, never SwiftUI/UI state.
@MainActor
struct ReaderTiledImage: UIViewRepresentable {
    let image: CGImage?

    func makeUIView(context: Context) -> ReaderTiledImageView {
        let view = ReaderTiledImageView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ReaderTiledImageView, context: Context) {
        view.setImage(image)
    }

    static func dismantleUIView(_ view: ReaderTiledImageView, coordinator: ()) {
        view.setImage(nil)
    }
}

@MainActor
final class ReaderTiledImageView: UIView {
    // Keep the tiled layer independent of UIView's backing-layer delegate.
    // UIKit owns that delegate; our child supplies its own thread-safe draw.
    private let tiles = ReaderImageTileLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(tiles)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        layer.addSublayer(tiles)
        clipsToBounds = true
    }

    func setImage(_ image: CGImage?) {
        tiles.setImage(image, size: bounds.size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tiles.frame = bounds
        tiles.setSize(bounds.size)
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Use the attached display, including external windows.
        tiles.contentsScale = window?.screen.scale ?? traitCollection.displayScale
    }
}

private final class ReaderImageTileLayer: CATiledLayer, @unchecked Sendable {
    private let lock = NSLock()
    private var sourceImage: CGImage?
    private var surfaceSize = CGSize.zero

    override class func fadeDuration() -> CFTimeInterval { 0 }

    override init() {
        super.init()
        tileSize = CGSize(width: 512, height: 512)
        levelsOfDetail = 1
        levelsOfDetailBias = 3 // The reader's zoom is bounded to 5×.
        isOpaque = false
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let original = layer as? ReaderImageTileLayer {
            (sourceImage, surfaceSize) = original.snapshot()
        }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    func setImage(_ image: CGImage?, size: CGSize) {
        lock.lock()
        let changed = sourceImage !== image || surfaceSize != size
        sourceImage = image
        surfaceSize = size
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    func setSize(_ size: CGSize) {
        lock.lock()
        let changed = surfaceSize != size
        surfaceSize = size
        lock.unlock()
        if changed { setNeedsDisplay() }
    }

    private func snapshot() -> (CGImage?, CGSize) {
        lock.lock()
        defer { lock.unlock() }
        return (sourceImage, surfaceSize)
    }

    override func draw(in context: CGContext) {
        let (image, size) = snapshot()
        guard let image else { return }
        NativeReaderTileRenderer.draw(image, surface: size, in: context)
    }
}
