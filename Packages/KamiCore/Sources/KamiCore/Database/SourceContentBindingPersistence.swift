import Foundation
import MihonCompatKit

#if canImport(SQLite3)
/// The only measured configurable content namespace. All calls run inside the
/// caller's database transaction; this type never opens files or executes APKs.
enum SourceContentBindingPersistence {
    static let sourceID: Int64 = 6_351_052_922_295_965_587
    static let packageName = "eu.kanade.tachiyomi.extension.all.foolslidecustomizable"

    static var schema: InterpretedExtensionPreferenceSchema? {
        InterpretedExtensionProfileCatalog.preferenceSchema(
            packageName: packageName, versionName: "1.6.6", versionCode: 6)
    }

    static func supports(_ candidate: InterpretedExtensionPreferenceSchema) -> Bool {
        candidate == schema
    }

    static func hasContent(_ db: SQLiteDatabase) throws -> Bool {
        try !db.query("SELECT 1 AS present FROM manga WHERE source_id=? LIMIT 1", [.int(sourceID)]).isEmpty
    }

    static func read(_ db: SQLiteDatabase) throws -> SourceContentBindingSnapshot? {
        let rows = try db.query("""
            SELECT
                CASE WHEN typeof(kind)='text' AND length(CAST(kind AS BLOB))<=10
                    THEN CAST(kind AS BLOB) END AS kind,
                CASE WHEN typeof(deployment_url)='text' AND length(CAST(deployment_url AS BLOB)) BETWEEN 1 AND 4096
                    THEN CAST(deployment_url AS BLOB) END AS url,
                deployment_url IS NULL AS url_is_null,
                CASE WHEN typeof(revision)='integer' THEN revision END AS revision
            FROM source_content_binding WHERE source_id=? LIMIT 2
            """, [.int(sourceID)])
        guard let row = rows.first else {
            guard try !hasContent(db) else { throw ExtensionPreferencesError.invalidContentBinding }
            return nil
        }
        guard rows.count == 1,
              let bytes = row.bytes("kind"), let text = String(bytes: bytes, encoding: .utf8),
              let kind = SourceContentBindingSnapshot.Kind(rawValue: text),
              let revision = row.int64("revision"), revision > 0 else {
            throw ExtensionPreferencesError.invalidContentBinding
        }
        let url: String?
        switch kind {
        case .unresolved:
            guard row.int("url_is_null") == 1 else { throw ExtensionPreferencesError.invalidContentBinding }
            url = nil
        case .deployment:
            guard let bytes = row.bytes("url"), !bytes.contains(0),
                  let value = String(bytes: bytes, encoding: .utf8), let schema,
                  (try? schema.validateUserValues([.baseURL: .string(value)])) != nil else {
                throw ExtensionPreferencesError.invalidContentBinding
            }
            url = value
        }
        return .init(sourceID: sourceID, kind: kind, deploymentURL: url, revision: revision)
    }

    /// Explicit settings Save may establish or change an empty namespace.
    /// Populated unresolved content cannot be relabelled with a guessed URL.
    static func save(
        _ db: SQLiteDatabase, expected: SourceContentBindingSnapshot?, url: String
    ) throws -> SourceContentBindingSnapshot {
        let current = try read(db)
        guard current == expected else { throw ExtensionPreferencesError.staleContentBinding }
        let populated = try hasContent(db)
        if let current {
            if current.matches(url) { return current }
            if populated {
                throw current.kind == .unresolved
                    ? ExtensionPreferencesError.unresolvedContent : .deploymentInUse
            }
            guard current.revision < Int64.max else { throw ExtensionPreferencesError.invalidContentBinding }
        } else if populated {
            throw ExtensionPreferencesError.invalidContentBinding
        }
        guard let schema, (try? schema.validateUserValues([.baseURL: .string(url)])) != nil else {
            throw ExtensionPreferencesError.invalidContentBinding
        }
        let revision = (current?.revision ?? 0) + 1
        if current != nil {
            try db.run("UPDATE source_content_binding SET kind='deployment',deployment_url=?,revision=? WHERE source_id=?",
                       [.text(url), .int(revision), .int(sourceID)])
        } else {
            try db.run("INSERT INTO source_content_binding(source_id,kind,deployment_url,revision) VALUES (?,'deployment',?,?)",
                       [.int(sourceID), .text(url), .int(revision)])
        }
        guard let saved = try read(db), saved.matches(url), saved.revision == revision else {
            throw ExtensionPreferencesError.invalidContentBinding
        }
        return saved
    }

    static func requireExecution(_ snapshot: ExtensionConfigurationSnapshot) throws {
        guard supports(snapshot.schema) else { throw ExtensionPreferencesError.unsupportedProfile }
        guard let binding = snapshot.contentBinding else { throw ExtensionPreferencesError.invalidContentBinding }
        guard binding.kind == .deployment else { throw ExtensionPreferencesError.unresolvedContent }
        guard case let .string(url)? = snapshot.userValues[.baseURL], binding.matches(url) else {
            throw ExtensionPreferencesError.contentBindingMismatch
        }
    }

    /// One-time migration inference from the prior measured, bounded saved
    /// document. Missing APK bytes/disablement affect execution, not description.
    private static func legacyURL(_ db: SQLiteDatabase) throws -> String? {
        guard try LibraryBackupSnapshotReader.hasBoundedFoolSlideConfiguration(db),
              let row = try db.query("""
                SELECT package_name,version_name,version_code,apk_path,repo_url,installed_at,enabled,
                    apk_sha256,signature_scheme,current_signers,signer_history,trust_source,source_ids
                FROM installed_extension WHERE package_name=? LIMIT 1
                """, [.text(packageName)]).first,
              let installed = LibraryStore.installedExtensionTrust(from: row),
              let schema, installed.packageName == schema.identity.packageName,
              installed.versionName == schema.identity.versionName,
              installed.versionCode == schema.identity.versionCode,
              installed.apkSHA256 == schema.identity.apkSHA256,
              installed.currentSigners == [schema.identity.signerFingerprint],
              installed.signerHistory.contains(schema.identity.signerFingerprint),
              installed.sourceIDs == schema.identity.sourceIDs,
              installed.sourceIDs == [sourceID] else { return nil }
        do {
            let snapshot = try ExtensionConfigurationReader.read(db, installed: installed, schema: schema)
            guard snapshot.revision > 0 else { return nil }
            return try schema.validateUserValues(snapshot.userValues).baseURL
        } catch is SQLiteDatabase.SQLiteError { throw ExtensionPreferencesError.storageUnavailable }
        catch { return nil }
    }

    static func migrate(_ db: SQLiteDatabase) throws {
        let url = try legacyURL(db)
        if let url {
            try db.run("INSERT INTO source_content_binding(source_id,kind,deployment_url,revision) VALUES (?,'deployment',?,1)",
                       [.int(sourceID), .text(url)])
        } else if try hasContent(db) {
            try db.run("INSERT INTO source_content_binding(source_id,kind,deployment_url,revision) VALUES (?,'unresolved',NULL,1)",
                       [.int(sourceID)])
        }
        // Seed before installing the namespace freeze. These invariants also
        // guard low-level manga ingress without granting execution authority.
        try db.execute("""
            CREATE TRIGGER foo_manga_requires_binding BEFORE INSERT ON manga
            WHEN NEW.source_id=6351052922295965587
                AND NOT EXISTS(SELECT 1 FROM source_content_binding WHERE source_id=NEW.source_id)
            BEGIN SELECT RAISE(ABORT,'content binding required'); END;
            CREATE TRIGGER foo_manga_update_requires_binding BEFORE UPDATE OF source_id ON manga
            WHEN NEW.source_id=6351052922295965587
                AND NOT EXISTS(SELECT 1 FROM source_content_binding WHERE source_id=NEW.source_id)
            BEGIN SELECT RAISE(ABORT,'content binding required'); END;
            CREATE TRIGGER foo_content_binding_no_delete BEFORE DELETE ON source_content_binding
            BEGIN SELECT RAISE(ABORT,'content binding retained'); END;
            CREATE TRIGGER foo_content_binding_no_reinsert BEFORE INSERT ON source_content_binding
            WHEN EXISTS(SELECT 1 FROM source_content_binding WHERE source_id=NEW.source_id)
            BEGIN SELECT RAISE(ABORT,'content binding already exists'); END;
            CREATE TRIGGER foo_content_binding_revision BEFORE UPDATE ON source_content_binding
            WHEN NEW.source_id!=OLD.source_id OR NEW.revision<=OLD.revision
            BEGIN SELECT RAISE(ABORT,'content binding revision must advance'); END;
            CREATE TRIGGER foo_content_binding_no_relabel BEFORE UPDATE ON source_content_binding
            WHEN EXISTS(SELECT 1 FROM manga WHERE source_id=OLD.source_id)
                AND (OLD.source_id!=NEW.source_id OR OLD.kind!=NEW.kind
                    OR CAST(OLD.deployment_url AS BLOB) IS NOT CAST(NEW.deployment_url AS BLOB))
            BEGIN SELECT RAISE(ABORT,'content binding in use'); END;
            """)
    }
}
#endif
