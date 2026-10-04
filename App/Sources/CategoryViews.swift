import SwiftUI
import KamiCore

struct CategoryAssignmentRequest: Identifiable {
    let id = UUID()
    let mangaIDs: Set<Int64>
    let title: String
    let context: LibraryMutationContext?
}

private struct CategoryNameRequest: Identifiable {
    let id = UUID()
    var category: KamiCore.Category?
    let context: LibraryMutationContext?
}

@MainActor
struct CategoriesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var nameRequest: CategoryNameRequest?
    @State private var deletionIDs = Set<Int64>()
    @State private var deletionContext: LibraryMutationContext?
    @State private var confirmDeletion = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        let snapshot = model.librarySnapshot
        let presentation = model.libraryPresentation
        NavigationStack {
            List {
                if let message = model.libraryError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                        Button("Retry") { model.performLibraryOperation(expected: presentation.generation) { await model.refreshLibrary() } }
                    }
                }
                if model.categories.isEmpty {
                    ContentUnavailableView(
                        "No categories",
                        systemImage: "folder",
                        description: Text("Create categories to organize your library.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(snapshot.categories) { category in
                            Button {
                                nameRequest = CategoryNameRequest(category: category, context: snapshot.mutationContext)
                            } label: {
                                HStack {
                                    Text(category.name).foregroundStyle(.primary)
                                    Spacer()
                                    if let id = category.id {
                                        Text("\(model.librarySnapshot.mangaCount(in: .category(id)))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .accessibilityHint("Rename category")
                        }
                        .onMove { offsets, destination in
                            move(from: offsets, to: destination, snapshot: snapshot)
                        }
                        .onDelete { offsets in
                            deletionIDs = Set(offsets.compactMap { index in
                                guard snapshot.categories.indices.contains(index) else { return nil }
                                return snapshot.categories[index].id
                            })
                            deletionContext = snapshot.mutationContext
                            confirmDeletion = !deletionIDs.isEmpty
                        }
                    } footer: {
                        Text("Tap a category to rename it. Use Edit to reorder categories. Deleting a category keeps its manga and reading history.")
                    }
                }
            }
            .disabled(busy)
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(busy)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton().disabled(busy || model.categories.isEmpty)
                    Button {
                        nameRequest = CategoryNameRequest(context: snapshot.mutationContext)
                    } label: {
                        Label("New category", systemImage: "plus")
                    }
                    .disabled(busy)
                }
            }
            .refreshable { await model.runLibraryOperation(expected: presentation.generation) { await model.refreshLibrary() } }
            .task(id: presentation) {
                guard !presentation.isExclusive else { return }
                await model.runLibraryOperation(expected: presentation.generation) { await model.refreshLibrary() }
            }
            .sheet(item: $nameRequest) { request in
                CategoryNameSheet(category: request.category) { name in
                    guard let context = request.context else { throw LibraryMutationError.snapshotUnavailable }
                    if let id = request.category?.id {
                        try await model.renameCategory(id: id, name: name, context: context)
                    } else {
                        try await model.createCategory(name: name, context: context)
                    }
                }
            }
            .confirmationDialog(
                deletionIDs.count == 1 ? "Delete category?" : "Delete \(deletionIDs.count) categories?",
                isPresented: $confirmDeletion,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    let ids = deletionIDs
                    let context = deletionContext
                    perform {
                        guard let context else { throw LibraryMutationError.snapshotUnavailable }
                        try await model.deleteCategories(ids: ids, context: context)
                    }
                }
            } message: {
                Text("The manga stay in your library. Their reading progress and history are kept.")
            }
            .alert("Could not update categories", isPresented: errorPresented) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .interactiveDismissDisabled(busy)
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private func move(from offsets: IndexSet, to destination: Int, snapshot: LibrarySnapshot) {
        var ids = snapshot.categories.compactMap(\.id)
        ids.move(fromOffsets: offsets, toOffset: destination)
        perform {
            guard let context = snapshot.mutationContext else { throw LibraryMutationError.snapshotUnavailable }
            try await model.reorderCategories(ids: ids, context: context)
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        let worker = model.performLibraryOperation {
            defer { busy = false }
            do { try await operation() }
            catch { errorText = model.libraryErrorMessage(for: error) }
        }
        if worker == nil { busy = false }
    }
}

@MainActor
private struct CategoryNameSheet: View {
    let category: KamiCore.Category?
    let onSave: @MainActor (String) async throws -> Void
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saving = false
    @State private var errorText: String?
    @FocusState private var nameFocused: Bool

    init(category: KamiCore.Category?, onSave: @escaping @MainActor (String) async throws -> Void) {
        self.category = category
        self.onSave = onSave
        _name = State(initialValue: category?.name ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Category name", text: $name)
                        .textInputAutocapitalization(.words)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Choose a unique name of up to 100 characters.")
                }
            }
            .disabled(saving)
            .navigationTitle(category == nil ? "New category" : "Rename category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { nameFocused = true }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving else { return }
        let savedName = name
        saving = true
        errorText = nil
        let worker = model.performLibraryOperation {
            defer { saving = false }
            do {
                try await onSave(savedName)
                dismiss()
            } catch {
                errorText = model.libraryErrorMessage(for: error)
            }
        }
        if worker == nil { saving = false }
    }
}

@MainActor
struct CategoryAssignmentSheet: View {
    let mangaIDs: Set<Int64>
    let title: String
    let context: LibraryMutationContext?
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = CategoryAssignmentDraft(mangaIDs: [], categoryIDsByManga: [:])
    @State private var ready = false
    @State private var saving = false
    @State private var showManagement = false
    @State private var errorText: String?

    private var selectionAvailable: Bool {
        context != nil && context == model.librarySnapshot.mutationContext
            && !mangaIDs.isEmpty && mangaIDs.isSubset(of: Set(model.library.compactMap(\.id)))
    }

    var body: some View {
        let presentation = model.libraryPresentation
        NavigationStack {
            Form {
                Section {
                    if !ready {
                        ProgressView()
                    } else if context == nil || context != model.librarySnapshot.mutationContext {
                        Label("The library changed. Reopen this screen to edit categories.",
                              systemImage: "exclamationmark.triangle")
                    } else if !selectionAvailable {
                        Label("One of these manga is no longer in your library.",
                              systemImage: "exclamationmark.triangle")
                    } else if model.categories.isEmpty {
                        Text("Create a category to organize this selection.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.categories) { category in
                            if let id = category.id {
                                categoryRow(category, id: id)
                            }
                        }
                    }
                } header: {
                    Text(title)
                } footer: {
                    if mangaIDs.count > 1 {
                        Text("A dash means only some selected manga use this category. Unchanged categories keep their current assignments.")
                    } else {
                        Text("Manga with no categories appear in Uncategorized.")
                    }
                }

                Section {
                    Button("Clear categories") {
                        draft.clear(categoryIDs: Set(model.categories.compactMap(\.id)))
                    }
                    .disabled(!ready || !selectionAvailable || model.categories.isEmpty)
                    Button("Reset changes", action: resetDraft).disabled(!draft.hasChanges)
                    Button("Manage categories") { showManagement = true }
                }
            }
            .disabled(saving)
            .navigationTitle("Set categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!ready || saving || !selectionAvailable || !draft.hasChanges)
                }
            }
            .task(id: presentation) {
                guard !presentation.isExclusive else { return }
                await model.runLibraryOperation(expected: presentation.generation) {
                    await model.refreshLibrary()
                    guard !Task.isCancelled else { return }
                    resetDraft()
                    ready = true
                }
            }
            .onChange(of: model.categories) { _, categories in
                draft.restrict(to: Set(categories.compactMap(\.id)))
            }
            .sheet(isPresented: $showManagement) { CategoriesView() }
            .alert("Could not save categories", isPresented: errorPresented) {
                Button("OK", role: .cancel) { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(saving)
    }

    private func categoryRow(_ category: KamiCore.Category, id: Int64) -> some View {
        let membership = draft.membership(of: id)
        let symbol: String
        let value: String
        switch membership {
        case .all: symbol = "checkmark.square.fill"; value = "Selected"
        case .some: symbol = "minus.square.fill"; value = "Some selected manga"
        case .none: symbol = "square"; value = "Not selected"
        }
        return Button { draft.toggle(id) } label: {
            HStack {
                Text(category.name).foregroundStyle(.primary)
                Spacer()
                Image(systemName: symbol)
            }
        }
        .accessibilityValue(value)
        .disabled(!ready || !selectionAvailable)
    }

    private var errorPresented: Binding<Bool> {
        Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })
    }

    private func resetDraft() {
        guard context != nil, context == model.librarySnapshot.mutationContext else {
            errorText = LibraryMutationError.staleEpoch.errorDescription
            return
        }
        draft = CategoryAssignmentDraft(mangaIDs: mangaIDs,
                                        categoryIDsByManga: model.librarySnapshot.categoryIDsByManga)
    }

    private func save() {
        guard ready, selectionAvailable, draft.hasChanges, let context, !saving else { return }
        let savedDraft = draft
        saving = true
        let worker = model.performLibraryOperation {
            defer { saving = false }
            do {
                try await model.updateCategories(savedDraft, context: context)
                dismiss()
            } catch {
                errorText = model.libraryErrorMessage(for: error)
            }
        }
        if worker == nil { saving = false }
    }
}
