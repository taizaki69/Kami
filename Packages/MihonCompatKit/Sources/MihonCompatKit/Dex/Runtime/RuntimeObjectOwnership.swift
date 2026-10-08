import Foundation

/// Opt-in ownership for private pinned-source sessions. Kotlin object graphs
/// can contain cycles (source -> lazy lambda -> source) that Swift ARC cannot
/// collect. Weak tracking does not extend an acyclic value's lifetime; retirement
/// severs only values allocated inside this owner, after execution has drained.
final class RuntimeObjectOwnership: @unchecked Sendable {
    @TaskLocal static var current: RuntimeObjectOwnership?

    private final class Entry {
        weak var object: ObjInstance?
        weak var array: ArrInstance?
        init(_ object: ObjInstance) { self.object = object }
        init(_ array: ArrInstance) { self.array = array }
        var isAlive: Bool { object != nil || array != nil }
    }
    private let lock = NSLock()
    private let maximumObjects: Int
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var nextSweep = 1_024
    private var retired = false

    init(maximumObjects: Int = 200_000) { self.maximumObjects = max(1, min(maximumObjects, 200_000)) }

    func register(_ object: ObjInstance) { register(ObjectIdentifier(object), entry: Entry(object)) }
    func register(_ array: ArrInstance) { register(ObjectIdentifier(array), entry: Entry(array)) }

    private func register(_ id: ObjectIdentifier, entry: Entry) {
        lock.lock()
        defer { lock.unlock() }
        if entries.count >= nextSweep {
            entries = entries.filter { $0.value.isAlive }
            nextSweep = max(1_024, entries.count * 2)
        }
        entries[id] = entry
    }

    /// Checked at VM instruction and source-operation boundaries. A host call's
    /// existing collection/JSON limits also bound allocations between checks.
    func check() throws {
        lock.lock()
        if entries.count > maximumObjects { entries = entries.filter { $0.value.isAlive } }
        let invalid = retired || entries.count > maximumObjects
        lock.unlock()
        if invalid { throw VMError.verify("retired or oversized source object session") }
    }

    func perform<T>(_ operation: () throws -> T) throws -> T {
        try Self.$current.withValue(self) {
            try check()
            let result = try operation()
            try check()
            return result
        }
    }

    func perform<T>(_ operation: () async throws -> T) async throws -> T {
        try await Self.$current.withValue(self) {
            try check()
            let result = try await operation()
            try check()
            return result
        }
    }

    /// The owning runtime must serialize this after all VM/host work drains.
    /// No interpreter callback or object destruction runs under the lock.
    func retire() {
        lock.lock()
        retired = true
        // Keep all live nodes alive while severing edges. Otherwise releasing
        // the first node of a long chain could recurse through ARC destructors
        // before the remaining weak entries can be cleared.
        let objects = entries.values.compactMap(\.object)
        let arrays = entries.values.compactMap(\.array)
        entries.removeAll()
        lock.unlock()
        for object in objects {
            object.fields.removeAll()
            object.payload = nil
        }
        for array in arrays { array.elements.removeAll() }
    }
}
