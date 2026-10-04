import SwiftUI
import MihonCompatKit
import KamiCore

/// A value-copy editor for the measured Foo profile. Loading and saving this
/// form never issue an execution admission or implicitly enable a source.
@MainActor
struct ExtensionConfigurationSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let packageName: String

    @State private var snapshot: ExtensionConfigurationSnapshot?
    @State private var baseURL = ""
    @State private var adult = true
    @State private var loading = true
    @State private var saving = false
    @State private var errorText: String?
    @State private var urlError: String?

    var body: some View {
        NavigationStack {
            Form {
                if loading {
                    Section { ProgressView("Loading saved settings…") }
                } else if snapshot != nil {
                    Section {
                        TextField("Source URL", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Source HTTPS URL")
                            .accessibilityHint("Use the FoolSlide website address without a trailing slash.")
                            .onChange(of: baseURL) { _, _ in urlError = nil }
                        if let urlError {
                            Label(urlError, systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Website")
                    } footer: {
                        Text("Enter the HTTPS address of your FoolSlide site, including its installation path if needed. Omit the trailing slash, login information, query, and fragment. Once manga from this source are saved, even outside your library, the URL stays fixed to protect their original website and reading history.")
                    }

                    Section {
                        Toggle("Confirm adult content", isOn: $adult)
                            .accessibilityHint("Send the site's adult-content confirmation when requesting chapter pages.")
                    } footer: {
                        Text("When enabled, chapter-page requests send the website's adult-content confirmation. This setting does not filter the catalogue.")
                    }

                    if let binding = snapshot?.contentBinding {
                        Section("Saved website") {
                            if let url = binding.deploymentURL {
                                Text(url).textSelection(.enabled)
                                Text("Use this exact address when configuring this source again. It cannot change while manga from this website are stored.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else {
                                Label("The original website of the saved manga is unknown.", systemImage: "exclamationmark.triangle")
                                Text("These settings cannot assign those manga to a different website.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if let snapshot, !snapshot.enabled {
                        Section {
                            Button("Save and enable") { save(enableAfterSaving: true) }
                                .disabled(saving || !canSubmit)
                        } footer: {
                            Text("Save keeps this extension disabled. Choose Save and enable only when you want to activate it now.")
                        }
                    }
                }

                if let errorText {
                    Section {
                        Label(errorText, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        Button("Reload saved settings") {
                            Task { await load() }
                        }
                        .disabled(saving || loading)
                    }
                }
                if saving {
                    Section { ProgressView("Saving settings…") }
                }
            }
            .disabled(saving || loading)
            .navigationTitle("FoolSlide settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(snapshot?.enabled == true ? "Save and apply" : "Save") {
                        save(enableAfterSaving: false)
                    }
                    .disabled(saving || loading || !canSubmit || !hasChanges)
                }
            }
            .interactiveDismissDisabled(saving)
            .task { await load() }
        }
    }

    private var userValues: [InterpretedExtensionPreferenceSchema.FieldID: InterpretedExtensionPreferenceSchema.Value] {
        [.baseURL: .string(baseURL), .adult: .boolean(adult)]
    }

    private var canSubmit: Bool {
        snapshot != nil && !baseURL.isEmpty
    }

    private var hasChanges: Bool {
        snapshot.map { !$0.matches(userValues: userValues) } ?? false
    }

    private func load() async {
        loading = true
        errorText = nil
        urlError = nil
        defer { loading = false }
        do {
            let loaded = try await model.extensionConfiguration(packageName: packageName)
            guard !Task.isCancelled else { return }
            snapshot = loaded
            if case let .string(value)? = loaded.userValues[.baseURL] {
                baseURL = value
            } else {
                baseURL = ""
            }
            if case let .boolean(value)? = loaded.userValues[.adult] ?? loaded.schema.defaultUserValues[.adult] {
                adult = value
            }
        } catch {
            guard !Task.isCancelled else { return }
            errorText = model.configurationErrorMessage(for: error)
        }
    }

    private func save(enableAfterSaving: Bool) {
        guard let snapshot, !saving else { return }
        errorText = nil
        urlError = nil
        let values = userValues
        do {
            _ = try snapshot.schema.validateUserValues(values)
        } catch {
            urlError = model.configurationErrorMessage(for: error)
            return
        }
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await model.saveExtensionConfiguration(
                    snapshot: snapshot,
                    userValues: values,
                    enableAfterSaving: enableAfterSaving
                )
                dismiss()
            } catch let error as ExtensionConfigurationSaveError {
                if case let .savedButInactive(saved, _) = error { self.snapshot = saved }
                errorText = error.errorDescription
            } catch {
                errorText = model.configurationErrorMessage(for: error)
            }
        }
    }
}
