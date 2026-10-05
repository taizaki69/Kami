import Foundation

/// Decoded-page ownership, independent of compressed-byte prefetch. Webtoon
/// visibility comes from viewport intersections, not LazyVStack's larger
/// realization window. Keep scalar layout measurements when releasing pixels.
public enum ReaderImageResidency {
    public static func indexes(
        pageCount: Int, currentIndex: Int, mode: ReaderMode,
        visiblePages: Set<Int> = [], memoryConstrained: Bool
    ) -> Set<Int> {
        guard pageCount > 0, (0..<pageCount).contains(currentIndex) else { return [] }
        var visible: Set<Int> = mode == .webtoon
            ? Set(visiblePages.filter { (0..<pageCount).contains($0) }) : []
        // Also cover a programmatic jump while its geometry is still pending.
        visible.insert(currentIndex)
        guard !memoryConstrained else { return visible }
        var resident = visible
        for index in visible {
            if index > 0 { resident.insert(index - 1) }
            if index < pageCount - 1 { resident.insert(index + 1) }
        }
        return resident
    }
}
