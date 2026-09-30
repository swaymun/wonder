import SwiftUI
import UIKit
import WonderPairing

// MARK: - Conversation chrome

/// Compact title with the project and provider; no provider avatar.
struct ProjectConversationHeader: View {
    let detail: ProjectConversationDetail
    var body: some View {
        VStack(spacing: 1) {
            Text(detail.title).font(.headline).lineLimit(1)
            Text("\(detail.projectName) · \(detail.family.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(detail.title), \(detail.projectName) project, \(detail.family.title)")
        .accessibilityIdentifier("project-conversation-header")
    }
}

/// Model, effort and access for one project thread. The provider family is
/// fixed once the thread exists; only models from that family are offered.
struct ProjectComposerSettings: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let chat: ChatSummary
    @State private var showingModel = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    private var detail: ProjectConversationDetail? { library.details[chat.id] }
    private var models: [BotOptions.Model] {
        (library.options?.models ?? []).filter { !$0.hidden && $0.family == detail?.family }
    }
    private var selected: BotOptions.Model? { models.first { $0.id == detail?.model } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                accessMenu
                Spacer(minLength: 0)
                Button { showingModel = true } label: {
                    Group {
                        if typeSize.isAccessibilitySize { Image(systemName: "slider.horizontal.3").font(.system(size: 20)) }
                        else {
                            HStack(spacing: 4) {
                                Text(selected?.displayName ?? detail?.model ?? "Model").lineLimit(1)
                                Image(systemName: "chevron.down").imageScale(.small)
                            }.font(.subheadline)
                        }
                    }.padding(.horizontal, 4).frame(minWidth: 44, minHeight: 44)
                }
                .disabled(saving || detail == nil)
                .accessibilityLabel("Model").accessibilityValue(selected?.displayName ?? "Default")
                .accessibilityIdentifier("project-composer-model")
            }
            if saving { ProgressView("Saving…").font(.caption).padding(.horizontal, 12) }
            if let failure { FailureDetails("Settings not saved", message: failure).padding(.horizontal, 12) }
        }
        .task(id: model.assignmentScope) { await library.loadOptions() }
        .sheet(isPresented: $showingModel) {
            NavigationStack {
                Form {
                    Section("Model") {
                        if models.isEmpty { Text("Models are unavailable. Check \(model.macName).").foregroundStyle(.secondary) }
                        ForEach(models) { option in
                            Button { Task { await save(["model": option.id]) } } label: {
                                HStack { Text(option.displayName); Spacer(); if detail?.model == option.id { Image(systemName: "checkmark") } }
                            }.foregroundStyle(.primary)
                        }
                    }
                    if let selected, !selected.reasoningEfforts.isEmpty {
                        Section("Reasoning") {
                            ForEach(selected.reasoningEfforts) { option in
                                Button { Task { await save(["model": selected.id, "effort": option.id]) } } label: {
                                    HStack { Text(option.label == "xhigh" ? "Extra high" : option.label.capitalized); Spacer(); if detail?.effort == option.id { Image(systemName: "checkmark") } }
                                }.foregroundStyle(.primary)
                            }
                        }
                    }
                    if let failure { FailureDetails("Settings not saved", message: failure) }
                }
                .disabled(saving || model.accessEnded)
                .navigationTitle(detail?.family.title ?? "Model").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { showingModel = false } }
            }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
    }
    private var accessMenu: some View {
        let family = detail?.family ?? .codex
        return Menu {
            ForEach(ProjectAccessMode.allCases) { mode in
                Button { Task { await save(["accessMode": mode.rawValue]) } } label: {
                    if detail?.accessMode == mode { Label(mode.title(for: family), systemImage: "checkmark") }
                    else { Text(mode.title(for: family)) }
                }
            }
            if let mode = detail?.accessMode { Section { Text(mode.detail(for: family)) } }
        } label: {
            Image(systemName: "shield").font(.system(size: 18)).frame(width: 44, height: 44)
                .foregroundStyle(detail?.accessMode == .fullAccess ? Color.orange : Color.primary)
        }
        .disabled(saving || detail == nil || model.accessEnded)
        .accessibilityLabel("Access").accessibilityValue(detail.map { $0.accessMode.title(for: $0.family) } ?? "")
        .accessibilityIdentifier("project-composer-access")
    }
    private func save(_ fields: [String: Any]) async {
        saving = true; failure = nil
        defer { saving = false }
        do { try await library.updateConversation(chat.id, fields: fields) }
        catch { failure = managementError(error) }
    }
}

/// Details for a project thread, including exact-ID continuation on the Mac.
struct ProjectConversationDetailsView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let chat: ChatSummary
    @Environment(\.dismiss) private var dismiss
    @State private var continuation: DesktopContinuation?
    @State private var continuationFailure: String?
    @State private var title = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var copied: String?
    private var detail: ProjectConversationDetail? { library.details[chat.id] }
    var body: some View {
        NavigationStack {
            Form {
                if let detail {
                    Section {
                        TextField("Thread name", text: $title).submitLabel(.done)
                            .onSubmit { Task { await save(["title": title]) } }
                        Toggle("Pin thread", isOn: Binding(get: { detail.isPinned }, set: { value in Task { await save(["isPinned": value]) } }))
                    }
                    Section("Project") {
                        LabeledContent("Project", value: detail.projectName)
                        LabeledContent("Agent", value: detail.family.title)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Working folder").font(.subheadline)
                            Text(detail.workingFolder).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if !detail.folderInProject {
                            Text("This folder is no longer part of the project. Add it back in project settings to continue here.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let notice = detail.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section {
                        if let continuation {
                            ForEach(continuation.options) { option in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(option.title).font(.headline)
                                    Text(option.detail).font(.footnote).foregroundStyle(.secondary)
                                    Text(option.command).font(.footnote.monospaced()).textSelection(.enabled)
                                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                                    Button(copied == option.id ? "Copied" : "Copy command", systemImage: copied == option.id ? "checkmark" : "doc.on.doc") {
                                        UIPasteboard.general.string = option.command
                                        copied = option.id
                                    }
                                    .accessibilityIdentifier("copy-continuation-" + option.id)
                                }.padding(.vertical, 4)
                            }
                            ForEach(continuation.notes, id: \.self) { note in Text(note).font(.footnote).foregroundStyle(.secondary) }
                        } else if let continuationFailure {
                            Text(continuationFailure).foregroundStyle(.secondary)
                        } else { ProgressView() }
                    } header: { Text("Continue on Mac") }
                } else {
                    ProgressView("Loading thread…")
                }
                if let failure { FailureDetails(message: failure) }
            }
            .disabled(saving || model.accessEnded)
            .navigationTitle("Thread").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") {
                    Task {
                        if title != detail?.title { await save(["title": title]) }
                        if failure == nil { dismiss() }
                    }
                }.disabled(saving)
            }
            .task {
                if detail == nil { _ = try? await library.loadDetail(chat.id) }
                title = detail?.title ?? chat.title
                do { continuation = try await library.continuation(chat.id) }
                catch PairingFailure.response(409) { continuationFailure = "Send the first message before continuing on your Mac." }
                catch { continuationFailure = "Continuation details are unavailable. Check \(model.macName)." }
            }
        }
    }
    private func save(_ fields: [String: Any]) async {
        saving = true; failure = nil
        defer { saving = false }
        do { try await library.updateConversation(chat.id, fields: fields) }
        catch { failure = managementError(error) }
    }
}

// MARK: - Project library

/// Create or edit a named group of folders on one Mac. Saving is metadata only.
struct ProjectEditorView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let project: ProjectSummary?
    var onSaved: (ProjectSummary) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folders: [String] = []
    @State private var primary = 0
    @State private var browsing = false
    @State private var saving = false
    @State private var failure: String?
    @State private var creation = ManagementDraft()
    private var frozen: Bool { project == nil && creation.values["payload"] != nil }
    private let creationKey = "project.new"
    @State private var nameEdited = false
    private var changed: Bool {
        guard let project else { return true }
        return name != project.name || folders != project.folders.map(\.path)
            || primary != (project.folders.firstIndex(where: \.isPrimary) ?? 0)
    }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 120 && !folders.isEmpty && folders.count <= 16 && changed && !saving && !model.accessEnded
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Computer") {
                        Label(model.macName, systemImage: "laptopcomputer").labelStyle(.titleAndIcon)
                    }
                    TextField("Project name", text: $name)
                        .onChange(of: name) { _, _ in nameEdited = true }
                        .accessibilityIdentifier("project-name")
                }
                Section {
                    ForEach(Array(folders.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 12) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                                Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if index == primary {
                                Text("Primary").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            } else {
                                Button("Make primary") { primary = index }.font(.caption).buttonStyle(.borderless)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(index == primary ? "Primary folder" : "")
                        .swipeActions {
                            Button("Remove", role: .destructive) { remove(at: index) }.disabled(folders.count == 1)
                        }
                    }
                    Button("Add folder", systemImage: "folder.badge.plus") { browsing = true }
                        .accessibilityIdentifier("project-add-folder")
                } header: { Text("Folders") } footer: {
                    Text("New threads start in the primary folder. Other folders are available to the agent in this project.")
                }
                if let failure { FailureDetails(message: failure) }
            }
            .disabled(saving || frozen)
            .navigationTitle(project == nil ? "New project" : "Edit project").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button(frozen ? "Retry create" : project == nil ? "Create" : "Save") { Task { await save() } }.disabled(!canSave).accessibilityIdentifier("project-save") }
                }
            }
            .sheet(isPresented: $browsing) {
                MacLocationBrowser(model: model, title: "Add folder", foldersOnly: true) { path, isDirectory in
                    guard isDirectory, !folders.contains(path) else { return }
                    folders.append(path)
                    if project == nil, !nameEdited || name.isEmpty, folders.count == 1 {
                        name = URL(fileURLWithPath: path).lastPathComponent
                        nameEdited = false
                    }
                }
            }
            .onAppear {
                guard folders.isEmpty else { return }
                guard let project else {
                    creation = model.managementDrafts?.load(creationKey) ?? ManagementDraft()
                    if let payload = creation.values["payload"], let data = payload.data(using: .utf8),
                       let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        name = value["name"] as? String ?? ""
                        folders = value["folders"] as? [String] ?? []
                        primary = value["primaryIndex"] as? Int ?? 0
                        failure = "The last create wasn’t confirmed. Retry to recover the same project."
                    }
                    return
                }
                name = project.name
                folders = project.folders.map(\.path)
                primary = project.folders.firstIndex(where: \.isPrimary) ?? 0
                nameEdited = true
            }
        }
    }
    private func remove(at index: Int) {
        folders.remove(at: index)
        if primary >= folders.count || primary == index { primary = 0 }
        else if primary > index { primary -= 1 }
    }
    private func save() async {
        saving = true; failure = nil
        defer { saving = false }
        do {
            let saved: ProjectSummary
            if let project {
                var fields: [String: Any] = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines)]
                if folders != project.folders.map(\.path) || primary != (project.folders.firstIndex(where: \.isPrimary) ?? 0) {
                    fields["folders"] = folders; fields["primaryIndex"] = primary; fields["rootsRevision"] = project.rootsRevision
                }
                saved = try await library.update(project.id, fields: fields)
            } else {
                guard let drafts = model.managementDrafts else { throw ReadFailure.resync }
                creation.values["payload"] = String(decoding: try JSONSerialization.data(withJSONObject: [
                    "name": name.trimmingCharacters(in: .whitespacesAndNewlines), "folders": folders, "primaryIndex": primary]), as: UTF8.self)
                try drafts.save(creation, key: creationKey)
                saved = try await library.createProject(requestID: creation.requestId, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        folders: folders, primaryIndex: primary)
                drafts.remove(creationKey)
            }
            onSaved(saved)
            dismiss()
        } catch PairingFailure.response(409) {
            failure = "These folders changed on another device. Close and reopen the project to see the latest folders."
        } catch PairingFailure.response(422) {
            if project == nil { creation = ManagementDraft(); model.managementDrafts?.remove(creationKey) }
            failure = "One of these folders can’t be used. Choose existing folders that don’t contain protected Mac settings."
        } catch { failure = managementError(error) }
    }
}

/// Included and hidden projects for one Mac. Hiding never deletes history.
struct ManageProjectsView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    /// Inside Settings the view is a navigation destination, not a sheet.
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var editing: ProjectSummary?
    @State private var creating = false
    @State private var choosing = false
    @State private var busy: Set<String> = []
    @State private var failure: String?
    private var filtered: [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = SidebarProjection.sorted(library.projects)
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        if embedded { content } else { NavigationStack { content.toolbar { Button("Done") { dismiss() } } } }
    }
    private var content: some View {
            List {
                if library.supportsProjects == false {
                    Text("Update Wonder on \(model.macName) to use Projects.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(filtered) { project in
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(project.name)
                                    Text(project.folders.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if busy.contains(project.id) { ProgressView() }
                                Toggle("Show in sidebar", isOn: Binding(get: { project.isIncluded }, set: { value in Task { await set(project, ["isIncluded": value]) } }))
                                    .labelsHidden()
                                    .accessibilityLabel("Show \(project.name) in sidebar")
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editing = project }
                            .swipeActions(edge: .leading) {
                                Button(project.isPinned ? "Unpin" : "Pin", systemImage: project.isPinned ? "pin.slash" : "pin") {
                                    Task { await set(project, ["isPinned": !project.isPinned]) }
                                }.tint(.orange)
                            }
                        }
                        if filtered.isEmpty && library.loadingProjects { ProgressView() }
                    } footer: {
                        Text("Hidden projects keep their threads on your Mac.")
                    }
                    Section {
                        Button("Add project", systemImage: "folder.badge.plus") { creating = true }
                        Button("Choose from your Mac", systemImage: "sparkles.rectangle.stack") { choosing = true }
                    }
                }
                if let failure { FailureDetails(message: failure) }
            }
            .searchable(text: $search, prompt: "Search projects")
            .navigationTitle("Projects on \(model.macName)").navigationBarTitleDisplayMode(.inline)
            .refreshable { await library.refresh() }
            .task { await library.refresh() }
            .sheet(item: $editing) { project in ProjectEditorView(model: model, library: library, project: project) }
            .sheet(isPresented: $creating) { ProjectEditorView(model: model, library: library, project: nil) }
            .sheet(isPresented: $choosing) { ChooseProjectsView(model: model, library: library) }
    }
    private func set(_ project: ProjectSummary, _ fields: [String: Any]) async {
        busy.insert(project.id); failure = nil
        defer { busy.remove(project.id) }
        do { _ = try await library.update(project.id, fields: fields) }
        catch { failure = managementError(error) }
    }
}

/// Suggestions from native Codex projects and Claude Code folders. Nothing is
/// selected by default and nothing is included until the owner confirms.
struct ChooseProjectsView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    var onFinish: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ProjectCandidate] = []
    @State private var partial: [ProjectPartialFailure] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?
    @State private var creating = false
    @State private var requestIDs: [String: String] = [:]
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates.filter { !$0.isIncluded }) { candidate in
                        Button {
                            if !selected.insert(candidate.id).inserted { selected.remove(candidate.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(candidate.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(candidate.name).foregroundStyle(.primary)
                                    Text(candidate.folders.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Text(candidate.sources.map(\.title).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityAddTraits(selected.contains(candidate.id) ? .isSelected : [])
                    }
                    if loading { ProgressView("Looking for projects…") }
                    else if candidates.allSatisfy(\.isIncluded) {
                        Text("No new suggestions. Add a project by choosing its folders.").foregroundStyle(.secondary)
                    }
                    ForEach(partial, id: \.self) { item in Text(item.detail).font(.footnote).foregroundStyle(.secondary) }
                } footer: {
                    Text("Only the projects you choose appear in Wonder.")
                }
                Section { Button("Choose folders instead", systemImage: "folder.badge.plus") { creating = true } }
                if let failure {
                    FailureDetails(message: failure)
                    Button("Try again") { Task { await load() } }
                }
            }
            .navigationTitle("Choose projects").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { onFinish(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() }
                    else { Button("Include \(selected.count)") { Task { await include() } }.disabled(selected.isEmpty) }
                }
            }
            .task { await load() }
            .sheet(isPresented: $creating) { ProjectEditorView(model: model, library: library, project: nil) }
        }
    }
    private func load() async {
        loading = true; failure = nil
        defer { loading = false }
        do {
            let response = try await library.candidates()
            candidates = response.candidates; partial = response.partial
        } catch PairingFailure.response(404) {
            failure = "Update Wonder on \(model.macName) to use Projects."
        } catch { failure = "Suggestions couldn’t be loaded. You can still choose folders." }
    }
    private func include() async {
        saving = true; failure = nil
        defer { saving = false }
        for candidate in candidates where selected.contains(candidate.id) {
            let request = requestIDs[candidate.id] ?? UUID().uuidString.lowercased()
            requestIDs[candidate.id] = request
            do {
                _ = try await library.createProject(requestID: request, name: candidate.name, folders: candidate.folders, primaryIndex: 0)
                selected.remove(candidate.id)
            } catch {
                failure = "\(candidate.name) couldn’t be included. Try again."
                return
            }
        }
        onFinish()
        dismiss()
    }
}
