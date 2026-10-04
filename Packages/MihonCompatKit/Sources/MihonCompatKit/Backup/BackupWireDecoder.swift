import Foundation

/// A backup-specific range cursor. Nested cursors share one CoW payload array;
/// length-delimited messages are never copied into generic field trees.
struct BackupWireDecoder {
    typealias Reader = TachibkReader
    typealias Scope = Reader.Scope
    typealias Feature = Reader.UnsupportedFeature
    typealias Error = Reader.Error

    let policy: Reader.Policy

    func decode(_ bytes: [UInt8], compression: Reader.Compression) throws -> Reader.DecodedBackup {
        var budget = Budget(policy: policy)
        var cursor = try Cursor(bytes: bytes, range: bytes.startIndex..<bytes.endIndex, depth: 1, policy: policy)
        var manga: [Reader.BackupManga] = []
        var categories: [Reader.BackupCategory] = []
        var sources: [Reader.BackupSource] = []
        while let field = try cursor.nextField(scope: .root, budget: &budget) {
            switch field.number {
            case 1:
                try budget.consume(.manga)
                manga.append(try decodeManga(cursor.message(field, scope: .root, policy: policy), budget: &budget))
            case 2:
                try budget.consume(.categories)
                categories.append(try decodeCategory(cursor.message(field, scope: .root, policy: policy), budget: &budget))
            case 101:
                try budget.consume(.sources)
                sources.append(try decodeSource(cursor.message(field, scope: .root, policy: policy), budget: &budget))
            case 100: try skipMessage(.legacySources, field, scope: .root, cursor: &cursor, budget: &budget)
            case 104: try skipMessage(.appPreferences, field, scope: .root, cursor: &cursor, budget: &budget)
            case 105: try skipMessage(.sourcePreferences, field, scope: .root, cursor: &cursor, budget: &budget)
            case 106: try skipMessage(.extensionStores, field, scope: .root, cursor: &cursor, budget: &budget)
            default: try skip(.unknownField, field, scope: .root, cursor: &cursor, budget: &budget)
            }
        }
        return Reader.DecodedBackup(compression: compression, manga: manga, categories: categories,
                                    sources: sources, coverage: budget.coverage)
    }

    private func decodeManga(_ input: Cursor, budget: inout Budget) throws -> Reader.BackupManga {
        var c = input
        var source: Int64?
        var url: String?
        var title = ""
        var artist: String?
        var author: String?
        var description: String?
        var genre: [String] = []
        var status = 0
        var thumbnail: String?
        var dateAdded: Int64 = 0
        var favorite = true
        var favoriteModifiedAt: Int64?
        var strategy = Reader.BackupUpdateStrategy.alwaysUpdate
        var initialized = false
        var chapters: [Reader.BackupChapter] = []
        var categories: [Int64] = []
        var history: [Reader.BackupHistory] = []

        while let f = try c.nextField(scope: .manga, budget: &budget) {
            switch f.number {
            case 1: source = try c.int64(f, scope: .manga)
            case 2: url = try c.string(f, scope: .manga, kind: .urlLength, budget: &budget)
            case 3: title = try c.string(f, scope: .manga, budget: &budget)
            case 4: artist = try c.string(f, scope: .manga, budget: &budget)
            case 5: author = try c.string(f, scope: .manga, budget: &budget)
            case 6: description = try c.string(f, scope: .manga, kind: .descriptionLength, budget: &budget)
            case 7: genre.append(try c.string(f, scope: .manga, budget: &budget))
            case 8: status = try c.int32(f, scope: .manga)
            case 9: thumbnail = try c.string(f, scope: .manga, kind: .urlLength, budget: &budget)
            case 13: dateAdded = try c.int64(f, scope: .manga)
            case 14, 103:
                try c.expect(f, wire: 0, scope: .manga)
                try skip(.readerSettings, f, scope: .manga, cursor: &c, budget: &budget)
            case 16:
                try budget.consume(.chapters)
                chapters.append(try decodeChapter(c.message(f, scope: .manga, policy: policy), budget: &budget))
            case 17:
                if f.wire == 0 {
                    try budget.consume(.categoryReferences)
                    categories.append(try c.int64(f, scope: .manga))
                } else if f.wire == 2 {
                    // Packed values share the parent message depth and each
                    // element consumes the cumulative membership budget.
                    let packedRange = try c.lengthDelimited()
                    var packed = c.rangeCursor(packedRange)
                    while !packed.isAtEnd {
                        try budget.consume(.categoryReferences)
                        categories.append(Int64(bitPattern: try packed.varint()))
                    }
                } else {
                    throw Error.wrongWireType(scope: .manga, field: f.number, wire: f.wire)
                }
            case 18: try skipMessage(.tracking, f, scope: .manga, cursor: &c, budget: &budget)
            case 100: favorite = try c.boolean(f, scope: .manga)
            case 101:
                try c.expect(f, wire: 0, scope: .manga)
                try skip(.chapterSettings, f, scope: .manga, cursor: &c, budget: &budget)
            case 102: try skipMessage(.legacyHistory, f, scope: .manga, cursor: &c, budget: &budget)
            case 104:
                try budget.consume(.history)
                history.append(try decodeHistory(c.message(f, scope: .manga, policy: policy), budget: &budget))
            case 105:
                let value = try c.int32(f, scope: .manga)
                guard let parsed = Reader.BackupUpdateStrategy(rawValue: value) else {
                    throw Error.invalidUpdateStrategy(Int64(value))
                }
                strategy = parsed
            case 106, 109:
                try c.expect(f, wire: 0, scope: .manga)
                try skip(.synchronizationMetadata, f, scope: .manga, cursor: &c, budget: &budget)
            case 107: favoriteModifiedAt = try c.int64(f, scope: .manga)
            case 108:
                try c.expect(f, wire: 2, scope: .manga)
                try skip(.excludedScanlators, f, scope: .manga, cursor: &c, budget: &budget)
            case 110:
                try c.expect(f, wire: 2, scope: .manga)
                try skip(.notes, f, scope: .manga, cursor: &c, budget: &budget)
            case 111: initialized = try c.boolean(f, scope: .manga)
            case 112: try skipMessage(.mangaMemo, f, scope: .manga, cursor: &c, budget: &budget)
            default: try skip(.unknownField, f, scope: .manga, cursor: &c, budget: &budget)
            }
        }
        let resolvedSource = try required(source, scope: .manga, field: 1)
        let resolvedURL = try identity(url, scope: .manga, field: 2)
        return Reader.BackupManga(url: resolvedURL, title: title, artist: artist, author: author,
                                  descriptionText: description, genre: genre, status: status,
                                  sourceId: resolvedSource, favorite: favorite, thumbnailURL: thumbnail,
                                  dateAdded: dateAdded, favoriteModifiedAt: favoriteModifiedAt,
                                  updateStrategy: strategy, initialized: initialized,
                                  categories: categories, chapters: chapters, history: history)
    }

    private func decodeCategory(_ input: Cursor, budget: inout Budget) throws -> Reader.BackupCategory {
        var c = input
        var name: String?
        var order: Int64 = 0
        var id: Int64 = 0
        var flags: Int64 = 0
        while let f = try c.nextField(scope: .category, budget: &budget) {
            switch f.number {
            case 1: name = try c.string(f, scope: .category, budget: &budget)
            case 2: order = try c.int64(f, scope: .category)
            case 3: id = try c.int64(f, scope: .category)
            case 100: flags = try c.int64(f, scope: .category)
            default: try skip(.unknownField, f, scope: .category, cursor: &c, budget: &budget)
            }
        }
        // An explicitly empty category name and default order/id 0 are retained;
        // the importer decides how that category maps to its local defaults.
        return Reader.BackupCategory(name: try required(name, scope: .category, field: 1),
                                     order: order, id: id, flags: flags)
    }

    private func decodeSource(_ input: Cursor, budget: inout Budget) throws -> Reader.BackupSource {
        var c = input
        var id: Int64?
        var name = ""
        while let f = try c.nextField(scope: .source, budget: &budget) {
            switch f.number {
            case 1: name = try c.string(f, scope: .source, budget: &budget)
            case 2: id = try c.int64(f, scope: .source)
            default: try skip(.unknownField, f, scope: .source, cursor: &c, budget: &budget)
            }
        }
        return Reader.BackupSource(id: try required(id, scope: .source, field: 2), name: name)
    }

    private func decodeChapter(_ input: Cursor, budget: inout Budget) throws -> Reader.BackupChapter {
        var c = input
        var url: String?
        var name: String?
        var scanlator: String?
        var read = false
        var bookmark = false
        var lastPage: Int64 = 0
        var dateFetch: Int64 = 0
        var dateUpload: Int64 = 0
        var number: Float = 0
        var order: Int64 = 0
        while let f = try c.nextField(scope: .chapter, budget: &budget) {
            switch f.number {
            case 1: url = try c.string(f, scope: .chapter, kind: .urlLength, budget: &budget)
            case 2: name = try c.string(f, scope: .chapter, budget: &budget)
            case 3: scanlator = try c.string(f, scope: .chapter, budget: &budget)
            case 4: read = try c.boolean(f, scope: .chapter)
            case 5: bookmark = try c.boolean(f, scope: .chapter)
            case 6: lastPage = try c.int64(f, scope: .chapter)
            case 7: dateFetch = try c.int64(f, scope: .chapter)
            case 8: dateUpload = try c.int64(f, scope: .chapter)
            case 9: number = try c.float(f, scope: .chapter)
            case 10: order = try c.int64(f, scope: .chapter)
            case 11, 12:
                try c.expect(f, wire: 0, scope: .chapter)
                try skip(.synchronizationMetadata, f, scope: .chapter, cursor: &c, budget: &budget)
            case 13: try skipMessage(.chapterMemo, f, scope: .chapter, cursor: &c, budget: &budget)
            default: try skip(.unknownField, f, scope: .chapter, cursor: &c, budget: &budget)
            }
        }
        return Reader.BackupChapter(url: try identity(url, scope: .chapter, field: 1),
                                    name: try required(name, scope: .chapter, field: 2), scanlator: scanlator,
                                    read: read, bookmark: bookmark, lastPageRead: lastPage,
                                    dateFetch: dateFetch, dateUpload: dateUpload, chapterNumber: number,
                                    sourceOrder: order)
    }

    private func decodeHistory(_ input: Cursor, budget: inout Budget) throws -> Reader.BackupHistory {
        var c = input
        var url: String?
        var lastRead: Int64?
        var duration: Int64 = 0
        while let f = try c.nextField(scope: .history, budget: &budget) {
            switch f.number {
            case 1: url = try c.string(f, scope: .history, kind: .urlLength, budget: &budget)
            case 2: lastRead = try c.int64(f, scope: .history)
            case 3: duration = try c.int64(f, scope: .history)
            default: try skip(.unknownField, f, scope: .history, cursor: &c, budget: &budget)
            }
        }
        return Reader.BackupHistory(url: try identity(url, scope: .history, field: 1),
                                    lastRead: try required(lastRead, scope: .history, field: 2),
                                    readDuration: duration)
    }

    private func required<T>(_ value: T?, scope: Scope, field: Int) throws -> T {
        guard let value else { throw Error.missingRequiredField(scope: scope, field: field) }
        return value
    }

    private func identity(_ value: String?, scope: Scope, field: Int) throws -> String {
        let value = try required(value, scope: scope, field: field)
        guard !value.isEmpty else { throw Error.emptyIdentity(scope: scope, field: field) }
        return value
    }

    private func skipMessage(_ feature: Feature, _ field: Field, scope: Scope,
                             cursor: inout Cursor, budget: inout Budget) throws {
        try cursor.expect(field, wire: 2, scope: scope)
        try skip(feature, field, scope: scope, cursor: &cursor, budget: &budget)
    }

    private func skip(_ feature: Feature, _ field: Field, scope: Scope,
                      cursor: inout Cursor, budget: inout Budget) throws {
        budget.record(feature, scope: scope, bytes: try cursor.skipValue(field.wire))
    }

    private struct Field {
        let number: Int
        let wire: Int
    }

    private struct Cursor {
        let bytes: [UInt8]
        let range: Range<Int>
        let depth: Int
        var position: Int

        init(bytes: [UInt8], range: Range<Int>, depth: Int, policy: Reader.Policy) throws {
            guard depth <= policy.maximumDepth else { throw Error.limitExceeded(.depth) }
            self.bytes = bytes
            self.range = range
            self.depth = depth
            self.position = range.lowerBound
        }

        private init(bytes: [UInt8], range: Range<Int>, depth: Int) {
            self.bytes = bytes
            self.range = range
            self.depth = depth
            self.position = range.lowerBound
        }

        var isAtEnd: Bool { position == range.upperBound }

        mutating func nextField(scope: Scope, budget: inout Budget) throws -> Field? {
            try Task.checkCancellation()
            guard !isAtEnd else { return nil }
            try budget.consume(.fields)
            let tag = try varint()
            let number = tag >> 3
            guard number > 0, number < (1 << 29) else { throw Error.invalidFieldNumber(scope: scope) }
            let wire = Int(tag & 7)
            guard wire == 0 || wire == 1 || wire == 2 || wire == 5 else {
                throw Error.unsupportedWireType(scope: scope, wire: wire)
            }
            return Field(number: Int(number), wire: wire)
        }

        mutating func varint() throws -> UInt64 {
            try Task.checkCancellation()
            let start = position
            var value: UInt64 = 0
            for index in 0..<10 {
                guard position < range.upperBound else { throw Error.malformedProtobuf(offset: position) }
                let byte = bytes[position]
                position += 1
                guard index < 9 || byte <= 1 else { throw Error.malformedProtobuf(offset: start) }
                value |= UInt64(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 { return value }
            }
            throw Error.malformedProtobuf(offset: start)
        }

        mutating func lengthDelimited() throws -> Range<Int> {
            let length = try varint()
            guard length <= UInt64(range.upperBound - position) else {
                throw Error.malformedProtobuf(offset: position)
            }
            let start = position
            position += Int(length)
            return start..<position
        }

        func expect(_ field: Field, wire: Int, scope: Scope) throws {
            guard field.wire == wire else {
                throw Error.wrongWireType(scope: scope, field: field.number, wire: field.wire)
            }
        }

        mutating func message(_ field: Field, scope: Scope, policy: Reader.Policy) throws -> Cursor {
            try expect(field, wire: 2, scope: scope)
            let nestedRange = try lengthDelimited()
            return try Cursor(bytes: bytes, range: nestedRange, depth: depth + 1, policy: policy)
        }

        func rangeCursor(_ range: Range<Int>) -> Cursor {
            Cursor(bytes: bytes, range: range, depth: depth)
        }

        mutating func int64(_ field: Field, scope: Scope) throws -> Int64 {
            try expect(field, wire: 0, scope: scope)
            return Int64(bitPattern: try varint())
        }

        mutating func int32(_ field: Field, scope: Scope) throws -> Int {
            let value = try int64(field, scope: scope)
            guard let value = Int32(exactly: value) else {
                throw Error.invalidInteger(scope: scope, field: field.number)
            }
            return Int(value)
        }

        mutating func boolean(_ field: Field, scope: Scope) throws -> Bool {
            try expect(field, wire: 0, scope: scope)
            let value = try varint()
            guard value <= 1 else { throw Error.invalidBoolean(scope: scope, field: field.number) }
            return value == 1
        }

        mutating func float(_ field: Field, scope: Scope) throws -> Float {
            try expect(field, wire: 5, scope: scope)
            guard range.upperBound - position >= 4 else { throw Error.malformedProtobuf(offset: position) }
            var word: UInt32 = 0
            for shift in 0..<4 { word |= UInt32(bytes[position + shift]) << (shift * 8) }
            position += 4
            let value = Float(bitPattern: word)
            guard value.isFinite else { throw Error.invalidFloat(scope: scope, field: field.number) }
            return value
        }

        mutating func string(_ field: Field, scope: Scope, kind: Reader.Limit = .stringLength,
                             budget: inout Budget) throws -> String {
            try expect(field, wire: 2, scope: scope)
            let value = try lengthDelimited()
            let perValueLimit: Int
            switch kind {
            case .urlLength: perValueLimit = budget.policy.maximumURLBytes
            case .descriptionLength: perValueLimit = budget.policy.maximumDescriptionBytes
            default: perValueLimit = budget.policy.maximumStringLengthBytes
            }
            guard value.count <= perValueLimit else { throw Error.limitExceeded(kind) }
            try budget.consumeStringBytes(value.count)
            guard let string = String(bytes: bytes[value], encoding: .utf8) else {
                throw Error.invalidUTF8(scope: scope, field: field.number)
            }
            return string
        }

        mutating func skipValue(_ wire: Int) throws -> Int {
            try Task.checkCancellation()
            switch wire {
            case 0:
                let start = position
                _ = try varint()
                return position - start
            case 2: return try lengthDelimited().count
            default:
                let size = wire == 1 ? 8 : 4
                guard size <= range.upperBound - position else { throw Error.malformedProtobuf(offset: position) }
                position += size
                return size
            }
        }
    }

    private struct Budget {
        struct CoverageKey: Hashable {
            let scope: Scope
            let feature: Feature
        }
        let policy: Reader.Policy
        var counts: [Reader.Limit: Int] = [:]
        var stringBytes = 0
        var skipped: [CoverageKey: (occurrences: Int, bytes: Int)] = [:]

        mutating func consume(_ kind: Reader.Limit) throws {
            try Task.checkCancellation()
            let maximum: Int
            switch kind {
            case .fields: maximum = policy.maximumFields
            case .manga: maximum = policy.maximumManga
            case .categories: maximum = policy.maximumCategories
            case .sources: maximum = policy.maximumSources
            case .chapters: maximum = policy.maximumChapters
            case .history: maximum = policy.maximumHistory
            case .categoryReferences: maximum = policy.maximumCategoryReferences
            default: preconditionFailure("non-count budget")
            }
            let current = counts[kind, default: 0]
            guard current < maximum else { throw Error.limitExceeded(kind) }
            counts[kind] = current + 1
        }

        mutating func consumeStringBytes(_ count: Int) throws {
            guard count <= policy.maximumStringBytes - stringBytes else {
                throw Error.limitExceeded(.stringBytes)
            }
            stringBytes += count
        }

        mutating func record(_ feature: Feature, scope: Scope, bytes: Int) {
            let key = CoverageKey(scope: scope, feature: feature)
            let current = skipped[key, default: (0, 0)]
            // Occurrences cannot exceed maximumFields and skipped ranges are
            // disjoint parts of the payload; neither addition can overflow.
            skipped[key] = (current.occurrences + 1, current.bytes + bytes)
        }

        var coverage: Reader.CoverageReport {
            Reader.CoverageReport(unsupported: skipped.map { key, value in
                Reader.CoverageItem(scope: key.scope, feature: key.feature,
                                    occurrences: value.occurrences, valueBytes: value.bytes)
            }.sorted {
                $0.scope.rawValue == $1.scope.rawValue
                    ? $0.feature.rawValue < $1.feature.rawValue
                    : $0.scope.rawValue < $1.scope.rawValue
            })
        }
    }
}
