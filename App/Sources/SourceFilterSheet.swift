import SwiftUI
import MihonCompatKit

/// A generic editor for the Mihon filter hierarchy exposed by `KamiSource`.
/// The sheet edits a value copy, so cancelling never mutates the active search.
struct SourceFilterSheet: View {
    let sourceName: String
    let defaults: [SourceFilter]
    let isFiltering: Bool
    let onApply: ([SourceFilter]) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [SourceFilter]

    init(
        sourceName: String,
        filters: [SourceFilter],
        defaults: [SourceFilter],
        isFiltering: Bool,
        onApply: @escaping ([SourceFilter]) -> Void,
        onClear: @escaping () -> Void
    ) {
        self.sourceName = sourceName
        self.defaults = defaults
        self.isFiltering = isFiltering
        self.onApply = onApply
        self.onClear = onClear
        _draft = State(initialValue: filters)
    }

    var body: some View {
        NavigationStack {
            Form {
                SourceFilterRows(filters: $draft)

                Section {
                    Button("Reset to source defaults") {
                        draft = defaults
                    }

                    if isFiltering {
                        Button("Clear filtered search", role: .destructive) {
                            onClear()
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Apply runs the source's search with this exact filter state. Cancel leaves the current results unchanged.")
                }
            }
            .navigationTitle("\(sourceName) Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(draft)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SourceFilterRows: View {
    @Binding var filters: [SourceFilter]

    var body: some View {
        ForEach(filters.indices, id: \.self) { index in
            SourceFilterRow(filter: $filters[index])
        }
    }
}

/// `AnyView` intentionally erases the recursive group branch. Without that
/// boundary, nested source groups form a recursive opaque SwiftUI body type.
private struct SourceFilterRow: View {
    @Binding var filter: SourceFilter

    var body: some View {
        content
    }

    private var content: AnyView {
        switch filter {
        case let .header(name):
            return AnyView(
                Text(name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            )

        case let .separator(name):
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    if !name.isEmpty {
                        Text(name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            )

        case let .select(name, values, state):
            guard !values.isEmpty else {
                return AnyView(LabeledContent(name, value: "No options"))
            }
            return AnyView(
                Picker(name, selection: selectBinding(
                    name: name,
                    values: values,
                    fallback: state
                )) {
                    ForEach(values.indices, id: \.self) { index in
                        Text(values[index]).tag(index)
                    }
                }
                .pickerStyle(.menu)
            )

        case let .text(name, state):
            return AnyView(
                TextField(name, text: textBinding(name: name, fallback: state))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            )

        case let .checkBox(name, state):
            return AnyView(
                Toggle(name, isOn: checkBoxBinding(name: name, fallback: state))
            )

        case let .triState(name, state):
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text(name)
                    Picker(name, selection: triStateBinding(
                        name: name,
                        fallback: state
                    )) {
                        Text("Ignore").tag(SourceFilter.TriState.ignore)
                        Text("Include").tag(SourceFilter.TriState.include)
                        Text("Exclude").tag(SourceFilter.TriState.exclude)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            )

        case let .group(name, filters):
            return AnyView(
                Section {
                    SourceFilterRows(filters: groupBinding(
                        name: name,
                        fallback: filters
                    ))
                } header: {
                    Text(name)
                }
            )

        case let .sort(name, values, state):
            guard !values.isEmpty else {
                return AnyView(LabeledContent(name, value: "No options"))
            }
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Picker(name, selection: sortIndexBinding(
                        name: name,
                        values: values,
                        fallback: state
                    )) {
                        Text("None").tag(-1)
                        ForEach(values.indices, id: \.self) { index in
                            Text(values[index]).tag(index)
                        }
                    }
                    .pickerStyle(.menu)

                    if sortSelection(name: name)?.index != nil {
                        Toggle("Ascending", isOn: sortDirectionBinding(
                            name: name,
                            values: values,
                            fallback: state
                        ))
                    }
                }
            )
        }
    }

    private func selectBinding(
        name: String,
        values: [String],
        fallback: Int
    ) -> Binding<Int> {
        Binding(
            get: {
                guard case let .select(_, _, state) = filter else {
                    return fallback
                }
                return state
            },
            set: { state in
                filter = .select(name: name, values: values, state: state)
            }
        )
    }

    private func textBinding(name: String, fallback: String) -> Binding<String> {
        Binding(
            get: {
                guard case let .text(_, state) = filter else { return fallback }
                return state
            },
            set: { state in
                filter = .text(name: name, state: state)
            }
        )
    }

    private func checkBoxBinding(name: String, fallback: Bool) -> Binding<Bool> {
        Binding(
            get: {
                guard case let .checkBox(_, state) = filter else { return fallback }
                return state
            },
            set: { state in
                filter = .checkBox(name: name, state: state)
            }
        )
    }

    private func triStateBinding(
        name: String,
        fallback: SourceFilter.TriState
    ) -> Binding<SourceFilter.TriState> {
        Binding(
            get: {
                guard case let .triState(_, state) = filter else {
                    return fallback
                }
                return state
            },
            set: { state in
                filter = .triState(name: name, state: state)
            }
        )
    }

    private func groupBinding(
        name: String,
        fallback: [SourceFilter]
    ) -> Binding<[SourceFilter]> {
        Binding(
            get: {
                guard case let .group(_, filters) = filter else {
                    return fallback
                }
                return filters
            },
            set: { filters in
                filter = .group(name: name, filters: filters)
            }
        )
    }

    private func sortSelection(name: String) -> SourceFilter.SortSelection? {
        guard case let .sort(currentName, _, selection) = filter,
              currentName == name else { return nil }
        return selection
    }

    private func sortIndexBinding(
        name: String,
        values: [String],
        fallback: SourceFilter.SortSelection?
    ) -> Binding<Int> {
        Binding(
            get: {
                guard case let .sort(_, _, selection) = filter else {
                    return fallback?.index ?? -1
                }
                return selection?.index ?? -1
            },
            set: { index in
                guard index >= 0 else {
                    filter = .sort(name: name, values: values, state: nil)
                    return
                }
                let ascending = sortSelection(name: name)?.ascending
                    ?? fallback?.ascending
                    ?? true
                filter = .sort(
                    name: name,
                    values: values,
                    state: .init(index: index, ascending: ascending)
                )
            }
        )
    }

    private func sortDirectionBinding(
        name: String,
        values: [String],
        fallback: SourceFilter.SortSelection?
    ) -> Binding<Bool> {
        Binding(
            get: {
                sortSelection(name: name)?.ascending
                    ?? fallback?.ascending
                    ?? true
            },
            set: { ascending in
                guard let selection = sortSelection(name: name) ?? fallback else {
                    return
                }
                filter = .sort(
                    name: name,
                    values: values,
                    state: .init(index: selection.index, ascending: ascending)
                )
            }
        )
    }
}
