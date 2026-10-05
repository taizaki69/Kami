import Foundation

public enum ReaderTapAction: String, CaseIterable, Codable, Sendable {
    case automatic, previousPage, nextPage, toggleControls, none

    public var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .previousPage: return "Previous page"
        case .nextPage: return "Next page"
        case .toggleControls: return "Show / hide controls"
        case .none: return "Do nothing"
        }
    }
}

public struct ReaderTapConfiguration: Codable, Equatable, Sendable {
    public var left: ReaderTapAction
    public var center: ReaderTapAction
    public var right: ReaderTapAction

    public init(left: ReaderTapAction = .automatic, center: ReaderTapAction = .automatic,
                right: ReaderTapAction = .automatic) {
        self.left = left; self.center = center; self.right = right
    }

    /// Fractions are physical left-to-right positions, independent of the
    /// environment's layout direction. Only Automatic reverses in RTL.
    public func action(at fraction: Double, mode: ReaderMode) -> ReaderTapAction {
        guard fraction.isFinite, (0...1).contains(fraction) else { return .none }
        let action = fraction < 0.25 ? left : (fraction > 0.75 ? right : center)
        guard action == .automatic else { return action }
        if mode == .webtoon || (0.25...0.75).contains(fraction) { return .toggleControls }
        let next = (fraction > 0.75) != (mode == .rightToLeft)
        return next ? .nextPage : .previousPage
    }
}

public enum ReaderPageFit: String, CaseIterable, Codable, Sendable {
    case fitPage, fitWidth, fitHeight

    public var title: String {
        switch self {
        case .fitPage: return "Fit whole page"
        case .fitWidth: return "Fit width"
        case .fitHeight: return "Fit height"
        }
    }
}

public struct ReaderPageOffset: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
}

/// Layout in points, independent of image decoding. Overflow is pannable even
/// at 1×; fit-width starts at the top and fit-height at the reading edge.
public struct ReaderPageLayout: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let initialOffset: ReaderPageOffset

    public init(imageWidth: Double, imageHeight: Double, viewportWidth: Double,
                viewportHeight: Double, fit: ReaderPageFit, rightToLeft: Bool = false) {
        guard [imageWidth, imageHeight, viewportWidth, viewportHeight].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            self.width = 0; self.height = 0; self.viewportWidth = 0; self.viewportHeight = 0
            self.initialOffset = .init(); return
        }
        let factor: Double
        switch fit {
        case .fitPage: factor = min(viewportWidth / imageWidth, viewportHeight / imageHeight)
        case .fitWidth: factor = viewportWidth / imageWidth
        case .fitHeight: factor = viewportHeight / imageHeight
        }
        let width = imageWidth * factor, height = imageHeight * factor
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= Double.greatestFiniteMagnitude / 5,
              height <= Double.greatestFiniteMagnitude / 5 else {
            self.width = 0; self.height = 0; self.viewportWidth = 0; self.viewportHeight = 0
            self.initialOffset = .init(); return
        }
        self.width = width; self.height = height
        self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight
        self.initialOffset = .init(x: max(0, (width - viewportWidth) / 2) * (rightToLeft ? -1 : 1),
                                   y: max(0, (height - viewportHeight) / 2))
    }

    public func canPan(scale: Double) -> Bool {
        let scale = Self.normalizedScale(scale)
        return width * scale > viewportWidth + 0.5 || height * scale > viewportHeight + 0.5
    }

    public func boundedOffset(_ offset: ReaderPageOffset, scale: Double) -> ReaderPageOffset {
        let scale = Self.normalizedScale(scale)
        let x = max(0, (width * scale - viewportWidth) / 2)
        let y = max(0, (height * scale - viewportHeight) / 2)
        return .init(x: offset.x.isFinite ? max(-x, min(x, offset.x)) : 0,
                     y: offset.y.isFinite ? max(-y, min(y, offset.y)) : 0)
    }

    public static func normalizedScale(_ value: Double) -> Double {
        value.isFinite ? max(1, min(5, value)) : 1
    }

    /// Anchor is measured from the viewport center in points. Keeping that
    /// content point fixed avoids jumping when zooming an already-panned page.
    public func zoomedOffset(_ offset: ReaderPageOffset, from oldScale: Double,
                             to newScale: Double, anchor: ReaderPageOffset = .init()) -> ReaderPageOffset {
        let ratio = Self.normalizedScale(newScale) / Self.normalizedScale(oldScale)
        let anchor = ReaderPageOffset(x: anchor.x.isFinite ? anchor.x : 0,
                                      y: anchor.y.isFinite ? anchor.y : 0)
        return boundedOffset(.init(x: anchor.x - (anchor.x - offset.x) * ratio,
                                   y: anchor.y - (anchor.y - offset.y) * ratio), scale: newScale)
    }
}
