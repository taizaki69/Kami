import SwiftUI
import KamiCore

extension MangaReadingSnapshot {
    /// These chapters and targets all belong to the same database read.
    var readerChapters: [Chapter] {
        var seen = Set<Int64>()
        let requested = requestedChapter.map { [$0] } ?? []
        return (currentChapters + downloadedChapters + requested).filter { chapter in
            guard let id = chapter.id else { return false }
            return seen.insert(id).inserted
        }.sorted {
            $0.sourceOrder == $1.sourceOrder ? ($0.id ?? 0) < ($1.id ?? 0) : $0.sourceOrder < $1.sourceOrder
        }
    }

    func target(for chapter: Chapter) -> ChapterWriteTarget? {
        guard let id = chapter.id, let target = target(for: id),
              target.mangaID == chapter.mangaId,
              Data(target.chapterURL.utf8) == Data(chapter.url.utf8) else { return nil }
        return target
    }
}

enum ReadingPresentation {
    static func requiresReopening(_ error: Error) -> Bool {
        guard let error = error as? ReadingStateError else { return false }
        switch error {
        case .foreignTarget, .staleEpoch, .identityChanged, .mangaNotFound, .chapterNotFound:
            return true
        default:
            return false
        }
    }

    static func message(_ error: Error) -> String {
        (error as? ReadingStateError)?.errorDescription
            ?? (error as? ReadingStateWriterError)?.errorDescription
            ?? "Reading progress could not be saved. Please try again."
    }
}

/// The queue belongs to AppModel, so failures remain actionable after the
/// reader/detail view that submitted the intent has disappeared.
@MainActor
struct ReadingSaveFailureBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let failure = model.readingWriteFailures.first {
            VStack(alignment: .leading, spacing: 8) {
                Label("Reading state could not be saved", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.bold())
                Text(failure.message).font(.footnote)
                HStack {
                    if failure.canRetry {
                        Button("Retry saving") { _ = model.readingStateWriter.retry(failure) }
                    }
                    Button("Dismiss") { model.readingStateWriter.dismissFailure(id: failure.id) }
                    if model.readingWriteFailures.count > 1 {
                        Text("\(model.readingWriteFailures.count) failed saves")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        } else if model.discardedReadingWriteFailures > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Label("Earlier reading saves failed", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.bold())
                Text("Some failed saves could not be retained. Review recently read chapters and their saved progress.")
                    .font(.footnote)
                Button("Dismiss") { model.readingStateWriter.acknowledgeDiscardedFailures() }
                    .font(.footnote)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }
}
