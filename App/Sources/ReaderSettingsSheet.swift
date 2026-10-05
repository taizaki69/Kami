import SwiftUI
import KamiCore

struct ReaderSettingsSheet: View {
    @Binding var modeRaw: String
    @Binding var backgroundRaw: String
    @Binding var keepScreenAwake: Bool
    @Binding var prefetchPages: Int
    @Binding var webtoonGap: Double
    @Binding var fitRaw: String
    @Binding var trimBorders: Bool
    @Binding var tapLeftRaw: String
    @Binding var tapCenterRaw: String
    @Binding var tapRightRaw: String
    @Binding var overrideBrightness: Bool
    @Binding var brightness: Double
    let brightnessAvailable: Bool

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
                    if mode != .webtoon {
                        Picker("Page fit", selection: $fitRaw) {
                            ForEach(ReaderPageFit.allCases, id: \.rawValue) { fit in
                                Text(fit.title).tag(fit.rawValue)
                            }
                        }
                        Text("Drag oversized pages to explore them; use tap actions to turn pages. Pinch or double-tap to zoom.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("Crop uniform borders", isOn: $trimBorders)
                    Text("Crops white, black or transparent margins. Turn off to see the full original page.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker("Background", selection: $backgroundRaw) {
                        ForEach(ReaderBackground.allCases, id: \.rawValue) { value in
                            Text(value.title).tag(value.rawValue)
                        }
                    }
                    Toggle("Keep screen awake", isOn: $keepScreenAwake)
                }

                Section {
                    Toggle("Override screen brightness", isOn: $overrideBrightness)
                        .disabled(!brightnessAvailable)
                    if !brightnessAvailable {
                        Text("Screen brightness is available on the built-in display.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if overrideBrightness {
                        let value = ReaderSettings.normalizedBrightness(brightness)
                        Text("Brightness: \(Int((value * 100).rounded()))%")
                        Slider(value: Binding(
                            get: { ReaderSettings.normalizedBrightness(brightness) },
                            set: { brightness = $0 }
                        ), in: ReaderSettings.minimumBrightness...1)
                        .accessibilityLabel("Reader brightness")
                    }
                } header: { Text("Brightness") } footer: {
                    Text("Applies while this reader is active. The most recently changed active reader controls a shared screen. System changes are preserved when the override ends.")
                }

                Section {
                    tapPicker("Left edge", selection: $tapLeftRaw)
                    tapPicker("Center", selection: $tapCenterRaw)
                    tapPicker("Right edge", selection: $tapRightRaw)
                    Button("Reset tap actions") {
                        tapLeftRaw = ReaderTapAction.automatic.rawValue
                        tapCenterRaw = ReaderTapAction.automatic.rawValue
                        tapRightRaw = ReaderTapAction.automatic.rawValue
                    }
                } header: { Text("Single-tap actions") } footer: {
                    Text("Automatic follows reading direction, with controls in the center. In Webtoon, Automatic shows controls everywhere. Next and previous move between pages, then chapters.")
                }

                Section {
                    let prefetch = max(0, min(prefetchPages, ReaderSettings.maximumPrefetchPages))
                    Stepper(
                        "Prefetch \(prefetch) page\(prefetch == 1 ? "" : "s")",
                        value: Binding(get: { max(0, min(prefetchPages, ReaderSettings.maximumPrefetchPages)) },
                                       set: { prefetchPages = $0 }),
                        in: 0...ReaderSettings.maximumPrefetchPages
                    )
                    if mode == .webtoon {
                        let gap = ReaderSettings(webtoonGap: webtoonGap).webtoonGap
                        VStack(alignment: .leading) {
                            Text("Page gap: \(Int(gap)) pt")
                            Slider(
                                value: Binding(get: { ReaderSettings(webtoonGap: webtoonGap).webtoonGap },
                                               set: { webtoonGap = $0 }),
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

    private func tapPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ReaderTapAction.allCases, id: \.rawValue) { action in
                Text(action.title).tag(action.rawValue)
            }
        }
    }
}
