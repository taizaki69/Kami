import Foundation

/// A description of stored content, independent of installation, preferences,
/// enablement and APK trust. Only database code can issue this local snapshot.
public struct SourceContentBindingSnapshot: Equatable, Sendable {
    public enum Kind: String, Sendable { case deployment, unresolved }

    public let sourceID: Int64
    public let kind: Kind
    public let revision: Int64
    private let deploymentBytes: Data?

    public var deploymentURL: String? {
        deploymentBytes.map { String(decoding: $0, as: UTF8.self) }
    }

    init(sourceID: Int64, kind: Kind, deploymentURL: String?, revision: Int64) {
        self.sourceID = sourceID
        self.kind = kind
        self.revision = revision
        self.deploymentBytes = deploymentURL.map { Data($0.utf8) }
    }

    func matches(_ url: String) -> Bool {
        kind == .deployment && deploymentBytes == Data(url.utf8)
    }
}
