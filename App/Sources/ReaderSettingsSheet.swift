import SwiftUI
import KamiCore

struct ReaderSettingsSheet: View {
    @Binding var modeRaw: String
    @Binding var backgroundRaw: String
    @Binding var keepScreenAwake: Bool
    @Binding var prefetchPages: Int
    @Binding var webtoonGap: Double

    @Environment(\.dismiss) private var dismiss

    private var mode: ReaderMode {
        ReaderMode(rawValue: modeRaw) ?? .leftToRight
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading mode") {
                    Picker("Reading mode", selection: $modeRaw) {
                        ForEach(ReaderMode.allCases, id: \.rawValue) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Display") {
                    Picker("Background", selection: $backgroundRaw) {
                        ForEach(ReaderBackground.allCases, id: \.rawValue) { value in
                            Text(value.title).tag(value.rawValue)
                        }
                    }
                    Toggle("Keep screen awake", isOn: $keepScreenAwake)
                }

                Section {
                    Stepper(
                        "Prefetch \(prefetchPages) page\(prefetchPages == 1 ? "" : "s")",
                        value: $prefetchPages,
                        in: 0...ReaderSettings.maximumPrefetchPages
                    )
                    if mode == .webtoon {
                        VStack(alignment: .leading) {
                            Text("Page gap: \(Int(webtoonGap)) pt")
                            Slider(
                                value: $webtoonGap,
                                in: 0...ReaderSettings.maximumWebtoonGap,
                                step: 1
                            )
                        }
                    }
                } header: {
                    Text("Loading")
                } footer: {
                    Text("Prefetching uses the same bounded, source-scoped image request pipeline as visible pages.")
                }
            }
            .navigationTitle("Reader settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
