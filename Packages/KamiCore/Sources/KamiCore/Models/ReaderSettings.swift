import Foundation

public enum ReaderMode: String, CaseIterable, Codable, Sendable {
    case leftToRight
    case rightToLeft
    case webtoon

    public var title: String {
        switch self {
        case .leftToRight: return "Left to right"
        case .rightToLeft: return "Right to left"
        case .webtoon: return "Webtoon"
        }
    }
}

public enum ReaderBackground: String, CaseIterable, Codable, Sendable {
    case black
    case gray
    case white

    public var title: String {
        rawValue.capitalized
    }
}

/// Persistable reader preferences with bounded values suitable for direct use
/// by the app. AppStorage stores the fields independently, while this value
/// provides one tested normalization contract.
public struct ReaderSettings: Codable, Equatable, Sendable {
    public static let maximumPrefetchPages = 8
    public static let maximumWebtoonGap = 32.0

    public var mode: ReaderMode
    public var background: ReaderBackground
    public var keepScreenAwake: Bool
    public var prefetchPages: Int
    public var webtoonGap: Double

    public init(
        mode: ReaderMode = .leftToRight,
        background: ReaderBackground = .black,
        keepScreenAwake: Bool = true,
        prefetchPages: Int = 3,
        webtoonGap: Double = 0
    ) {
        self.mode = mode
        self.background = background
        self.keepScreenAwake = keepScreenAwake
        self.prefetchPages = max(0, min(prefetchPages, Self.maximumPrefetchPages))
        self.webtoonGap = max(0, min(webtoonGap, Self.maximumWebtoonGap))
    }
}

/// The small, deterministic window used by the reader's network prefetcher.
/// Forward pages are prioritized, followed by a bounded recently-read window.
public enum ReaderPrefetchPlan {
    public static func indexes(
        pageCount: Int,
        currentIndex: Int,
        ahead: Int,
        behind: Int = 1
    ) -> [Int] {
        guard pageCount > 0, currentIndex >= 0, currentIndex < pageCount else {
            return []
        }

        let forwardCount = max(0, min(ahead, ReaderSettings.maximumPrefetchPages))
        let backwardCount = max(0, min(behind, ReaderSettings.maximumPrefetchPages))
        var result: [Int] = []
        result.reserveCapacity(forwardCount + backwardCount)

        if forwardCount > 0, currentIndex + 1 < pageCount {
            let end = min(pageCount - 1, currentIndex + forwardCount)
            result.append(contentsOf: (currentIndex + 1)...end)
        }
        if backwardCount > 0, currentIndex > 0 {
            let start = max(0, currentIndex - backwardCount)
            result.append(contentsOf: (start..<currentIndex).reversed())
        }
        return result
    }
}
