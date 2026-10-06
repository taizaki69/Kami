import SwiftUI
import KamiCore

@MainActor
struct SourceSelectionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var sourceIDs: Set<Int64>?
    @State private var languages: Set<String>?
    @State private var revision: UUID
    @State private var message: String?

    init(initial: SourceDiscoveryState) {
        _sourceIDs = State(initialValue: initial.preferences.sourceIDs)
        _languages = State(initialValue: initial.preferences.languages)
        _revision = State(initialValue: initial.revision)
    }

    private var availableIDs: Set<Int64> { Set(model.sources.map(\.id)) }
    private var availableLanguages: Set<String> {
        Set(model.sources.compactMap { SourceDiscoveryPreferences.languageKey($0.language) })
    }
    private var unavailableIDs: [Int64] { (sourceIDs ?? []).subtracting(availableIDs).sorted() }
    private var languageChoices: [String] { availableLanguages.union(languages ?? []).sorted() }
    private var stale: Bool { revision != model.sourceDiscovery.revision }
    private var selectedCount: Int {
        guard let preferences = try? SourceDiscoveryPreferences(sourceIDs: sourceIDs, languages: languages) else { return 0 }
        return model.sources.filter { preferences.includes(sourceID: $0.id, language: $0.language) }.count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose the sources shown in Browse and queried by global search. Your library, updates and downloads remain available.")
                        .font(.footnote)
                    Text("\(selectedCount) of \(model.sources.count) enabled sources match both selections.")
                    if selectedCount > GlobalSearchSession.maximumSources {
                        Text("Select up to 64 sources to use global search. You can still browse sources individually.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if model.sourceDiscovery.requiresRecovery {
                        Text("The saved selection is unavailable. Searching is disabled until you review and apply a selection.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if stale {
                        Text("The selection changed while you were editing.")
                        Button("Reload current selection") { reload() }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
                Section {
                    Toggle("All languages", isOn: Binding(
                        get: { languages == nil },
                        set: { languages = $0 ? nil : availableLanguages }
                    ))
                    ForEach(languageChoices, id: \.self) { language in
                        Toggle(isOn: Binding(
                            get: { languages?.contains(language) ?? true },
                            set: { enabled in
                                var chosen = languages ?? availableLanguages
                                if enabled { chosen.insert(language) } else { chosen.remove(language) }
                                languages = chosen
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(languageTitle(language))
                                Text(language).font(.caption).foregroundStyle(.secondary)
                                if !availableLanguages.contains(language) {
                                    Text("No enabled source for this language").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("Languages") } footer: {
                    Text("All languages includes languages enabled later. An explicit selection keeps only the chosen tags; regional variants and multi-language sources are separate choices.")
                }
                Section {
                    Toggle("All enabled sources", isOn: Binding(
                        get: { sourceIDs == nil },
                        set: { sourceIDs = $0 ? nil : availableIDs }
                    ))
                    ForEach(model.sources, id: \.id) { source in
                        Toggle(isOn: sourceBinding(source.id)) {
                            VStack(alignment: .leading) {
                                Text(source.name)
                                Text(source.language).font(.caption).foregroundStyle(.secondary)
                                if let languages,
                                   !languages.contains(SourceDiscoveryPreferences.languageKey(source.language) ?? "") {
                                    Text("Excluded by language selection").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: { Text("Sources") } footer: {
                    Text("All enabled sources includes sources enabled later. Choosing sources here does not install or enable them. Apply with none selected to hide all sources from Browse and global search.")
                }
                if !unavailableIDs.isEmpty {
                    Section {
                        ForEach(unavailableIDs, id: \.self) { id in
                            Toggle(isOn: sourceBinding(id)) {
                                VStack(alignment: .leading) {
                                    Text("Unavailable source")
                                    Text(String(id)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("Remembered selections") } footer: {
                        Text("These choices are kept while a source is disabled or absent. They apply if the same source ID becomes available again.")
                    }
                }
            }
            .navigationTitle("Sources and languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { apply() }.disabled(stale) }
            }
        }
    }

    private func sourceBinding(_ id: Int64) -> Binding<Bool> {
        Binding(get: { sourceIDs?.contains(id) ?? true }, set: { enabled in
            var chosen = sourceIDs ?? availableIDs
            if enabled { chosen.insert(id) } else { chosen.remove(id) }
            sourceIDs = chosen
        })
    }

    private func languageTitle(_ language: String) -> String {
        language == "all" ? "Multi-language" : Locale.current.localizedString(forIdentifier: language) ?? language
    }

    private func reload() {
        let state = model.sourceDiscovery
        sourceIDs = state.preferences.sourceIDs
        languages = state.preferences.languages
        revision = state.revision
        message = nil
    }

    private func apply() {
        do {
            let preferences = try SourceDiscoveryPreferences(sourceIDs: sourceIDs, languages: languages)
            try model.saveSourceDiscovery(preferences, expectedRevision: revision)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
