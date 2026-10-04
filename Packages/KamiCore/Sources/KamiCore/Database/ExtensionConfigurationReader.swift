import Foundation
import MihonCompatKit

#if canImport(SQLite3)
/// Pure database decoding shared with one-time migration inference. Callers
/// own the surrounding transaction and any installation authentication.
enum ExtensionConfigurationReader {
    static func read(
        _ db: SQLiteDatabase, installed: InstalledExtensionTrust,
        schema: InterpretedExtensionPreferenceSchema,
        contentBinding: SourceContentBindingSnapshot? = nil
    ) throws -> ExtensionConfigurationSnapshot {
        let fingerprint = try ExtensionPreferenceBinding.fingerprint(installed)
        let row = try db.query("""
            SELECT
                CASE WHEN typeof(identity_fingerprint)='text'
                    AND length(CAST(identity_fingerprint AS BLOB))=64
                    THEN CAST(identity_fingerprint AS BLOB) END AS fingerprint,
                CASE WHEN typeof(schema_revision)='integer' THEN schema_revision END AS schema_revision,
                CASE WHEN typeof(revision)='integer' THEN revision END AS revision,
                CASE WHEN typeof(user_values)='text'
                    AND length(CAST(user_values AS BLOB))<=?
                    THEN CAST(user_values AS BLOB) END AS payload
            FROM installed_extension_preferences WHERE package_name=? LIMIT 1
            """, [.int(StoredExtensionPreferenceValues.maximumBytes), .text(installed.packageName)]).first
        let userValues: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value]
        let revision: Int64
        if let row {
            guard try text(row, "fingerprint") == fingerprint,
                  row.int("schema_revision") == schema.revision,
                  let storedRevision = row.int64("revision"), storedRevision > 0 else {
                throw ExtensionPreferencesError.invalidStoredConfiguration
            }
            userValues = try StoredExtensionPreferenceValues.decode(text(row, "payload"), schema: schema).userValues
            revision = storedRevision
        } else {
            userValues = schema.defaultUserValues
            revision = 0
        }
        return ExtensionConfigurationSnapshot(
            installed: installed, schema: schema, userValues: userValues,
            identityFingerprint: fingerprint, revision: revision, contentBinding: contentBinding
        )
    }

    private static func text(_ row: SQLiteDatabase.Row, _ field: String) throws -> String {
        guard let bytes = row.bytes(field), !bytes.contains(0),
              let value = String(bytes: bytes, encoding: .utf8) else {
            throw ExtensionPreferencesError.invalidStoredConfiguration
        }
        return value
    }
}
#endif
