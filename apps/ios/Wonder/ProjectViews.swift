import SwiftUI
import UIKit
import WonderPairing

// MARK: - Provider identity

/// The Codex or Claude app icon at a fixed size. It stands in for the words
/// "Codex" and "Claude" in rows and buttons; VoiceOver still hears the name.
struct ProviderIcon: View {
    let family: AgentFamily
    var size: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    var body: some View {
        Image(family == .claude ? "ProviderClaude" : "ProviderCodex")
            .resizable().interpolation(.high).scaledToFit()
            .frame(width: size * scale, height: size * scale)
            .accessibilityLabel(family.title)
    }
}

/// The last model and effort chosen for each provider. New threads start from
/// them; the choice is per provider, never a silent substitution.
enum RememberedModels {
    private static func key(_ family: AgentFamily) -> String { "wonder.project.model." + family.rawValue }
    static func load(_ family: AgentFamily?, defaults: UserDefaults = .standard) -> RememberedModel? {
        guard let family, let data = defaults.data(forKey: key(family)) else { return nil }
        return try? JSONDecoder().decode(RememberedModel.self, from: data)
    }
    static func save(_ family: AgentFamily, model: String, effort: String?, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(RememberedModel(model: model, effort: effort)) else { return }
        defaults.set(data, forKey: key(family))
    }
}

// MARK: - Composer controls shared by new chats and threads

/// Provider icon and "Model · Effort", the button that opens the model sheet.
struct ComposerModelLabel: View {
    let family: AgentFamily?
    let title: String
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Image(systemName: "slider.horizontal.3").font(.system(size: 20))
            } else {
                HStack(spacing: 5) {
                    if let family { ProviderIcon(family: family, size: 16) }
                    Text(title).lineLimit(1).minimumScaleFactor(0.8).layoutPriority(-1)
                    Image(systemName: "chevron.down").imageScale(.small)
                }.font(.subheadline)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 4).frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Shows that plan mode is on; tapping turns it off.
struct PlanModeChip: View {
    var isDisabled = false
    let turnOff: () -> Void
    var body: some View {
        Button(action: turnOff) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.clipboard").imageScale(.small)
                Text("Plan")
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("Plan mode on")
        .accessibilityHint("Turns plan mode off")
        .accessibilityIdentifier("plan-mode-chip")
    }
}

/// The shield menu for a project thread or draft. Rows and labels follow the
/// provider; `choose` receives the row the owner picked.
struct ProjectAccessMenu: View {
    let family: AgentFamily
    let supportsModes: Bool
    let access: ProjectAccess
    var isDisabled = false
    let identifier: String
    let choose: (ProjectAccessChoice) -> Void
    var body: some View {
        let selected = ProjectAccessChoice.selected(for: access, family: family, supportsModes: supportsModes)
        let plan = ProjectAccessChoice.planChoice(family: family, supportsModes: supportsModes)
        // With Plan shown separately, the level keeps its checkmark while planning.
        let level = plan == nil ? selected : ProjectAccessChoice.selected(
            for: ProjectAccess(accessMode: access.accessMode, claudeApproval: access.claudeApproval), family: family, supportsModes: supportsModes)
        Menu {
            ForEach(ProjectAccessChoice.choices(family: family, supportsModes: supportsModes, current: access)) { choice in
                row(choice, isSelected: choice == level)
            }
            if let plan {
                Divider()
                row(plan, isSelected: access.planMode)
            }
        } label: {
            Image(systemName: "shield").font(.system(size: 18)).frame(width: 44, height: 44)
                .foregroundStyle(selected.isElevated ? Color.orange : Color.primary)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .disabled(isDisabled)
        .accessibilityLabel("Access")
        .accessibilityValue(selected.title(for: family, supportsModes: supportsModes))
        .accessibilityIdentifier(identifier)
    }
    private func row(_ choice: ProjectAccessChoice, isSelected: Bool) -> some View {
        Button { choose(choice) } label: {
            Text(choice.title(for: family, supportsModes: supportsModes))
            Text(choice.detail(for: family))
            if isSelected { Image(systemName: "checkmark") }
        }
        .tint(choice.isElevated ? Color.orange : nil)
        .accessibilityIdentifier("access-choice-" + choice.rawValue)
    }
}

// MARK: - Conversation chrome

/// Compact title with the provider icon and project name.
struct ProjectConversationHeader: View {
    let detail: ProjectConversationDetail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        VStack(spacing: 1) {
            Text(detail.title).font(.headline).lineLimit(1)
            if !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 4) {
                    ProviderIcon(family: detail.family, size: 12)
                    Text(detail.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: 240)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(detail.title), \(detail.projectName) project, \(detail.family.title)")
        .accessibilityIdentifier("project-conversation-header")
    }
}

/// Turns a project thread's plan mode on or off. Sending waits for the save,
/// and a failure is reported in the composer.
@MainActor @discardableResult func setPlanMode(_ enabled: Bool, model: ConnectionModel, library: ProjectLibrary, chat: ChatSummary) async -> Bool {
    guard library.supportsModes, !model.savingComposerSettings.contains(chat.id), !model.accessEnded else { return false }
    let scope = model.assignmentScope
    model.savingComposerSettings.insert(chat.id); model.controlErrors[chat.id] = nil
    defer { if scope == model.assignmentScope { model.savingComposerSettings.remove(chat.id) } }
    do {
        try await library.updateConversation(chat.id, fields: ["planMode": enabled])
        return !Task.isCancelled && scope == model.assignmentScope && library.details[chat.id]?.planMode == enabled
    } catch {
        if scope == model.assignmentScope { model.controlErrors[chat.id] = "Plan mode wasn’t changed. " + managementError(error) }
        return false
    }
}

/// Model, effort and access for one project thread. The provider is fixed once
/// the thread exists; only models from that provider are offered.
struct ProjectComposerSettings: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let chat: ChatSummary
    @State private var showingModel = false
    @State private var failure: String?
    private var detail: ProjectConversationDetail? { library.details[chat.id] }
    private var saving: Bool { model.savingComposerSettings.contains(chat.id) }
    private var models: [BotOptions.Model] {
        (library.options?.models ?? []).filter { !$0.hidden && $0.family == detail?.family }
    }
    /// A thread that never chose a model uses its provider's default.
    private var selected: BotOptions.Model? {
        guard let detail else { return nil }
        if let stored = detail.model { return models.first { $0.id == stored } }
        return ModelDefaults.defaultModel(in: models)
    }
    private var effort: String? { selected.flatMap { ModelDefaults.effort(detail?.effort, for: $0) } }
    private var title: String {
        if let selected {
            let summary = ModelDefaults.summary(model: selected, effort: effort)
            let speed = selected.serviceTiers?.first { $0.id == detail?.serviceTier }
            return speed.map { $0.id == "default" ? summary : summary + " · " + $0.label } ?? summary
        }
        return detail?.model ?? "Model"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                accessMenu
                Spacer(minLength: 0)
                Button { showingModel = true } label: { ComposerModelLabel(family: detail?.family, title: title) }
                    .disabled(saving || detail == nil)
                    .accessibilityLabel("Model").accessibilityValue(title)
                    .accessibilityIdentifier("project-composer-model")
            }
            if saving { ProgressView("Saving…").font(.caption).padding(.horizontal, 12) }
            if let failure { FailureDetails("Settings not saved", message: failure).padding(.horizontal, 12) }
        }
        .task(id: model.assignmentScope + ":" + String(model.macConnected == true)) { await library.loadOptions() }
        .sheet(isPresented: $showingModel) {
            NavigationStack {
                Form {
                    Section("Model") {
                        if models.isEmpty { Text("Models are unavailable. Check \(model.macName).").foregroundStyle(.secondary) }
                        ForEach(models) { option in
                            Button { Task { await choose(option) } } label: {
                                HStack { Text(option.displayName); Spacer(); if option.id == selected?.id { Image(systemName: "checkmark") } }
                            }.foregroundStyle(.primary)
                        }
                    }
                    if let selected, !selected.reasoningEfforts.isEmpty {
                        Section("Reasoning") {
                            ForEach(selected.reasoningEfforts) { option in
                                Button { Task { await choose(selected, effort: option.id) } } label: {
                                    HStack { Text(ModelDefaults.title(of: option)); Spacer(); if option.id == effort { Image(systemName: "checkmark") } }
                                }.foregroundStyle(.primary)
                            }
                        }
                    }
                    if let selected, let tiers = selected.serviceTiers, tiers.count > 1 {
                        Section("Speed") {
                            ForEach(tiers) { option in
                                Button { Task { await chooseSpeed(option.id, model: selected) } } label: {
                                    HStack(alignment: .firstTextBaseline) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.label)
                                            if let description = option.description {
                                                Text(description).font(.footnote).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        if option.id == (detail?.serviceTier ?? "default") { Image(systemName: "checkmark") }
                                    }
                                }
                                .accessibilityIdentifier("project-speed:\(option.id)")
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
        ProjectAccessMenu(family: detail?.family ?? .codex, supportsModes: library.supportsModes, access: detail?.access ?? ProjectAccess(),
                          isDisabled: saving || detail == nil || model.accessEnded, identifier: "project-composer-access") { choice in
            guard let detail else { return }
            let next = choice.result(from: detail.access, family: detail.family, supportsModes: library.supportsModes)
            Task { _ = await save(detail.access.changes(to: next, family: detail.family, supportsModes: library.supportsModes)) }
        }
    }
    /// Picking a model starts from that model's default effort.
    private func choose(_ option: BotOptions.Model, effort: String? = nil) async {
        // Choosing the current model again keeps the effort already chosen.
        guard let family = detail?.family, effort != nil || option.id != selected?.id else { return }
        let chosen = effort ?? ModelDefaults.effort(for: option)
        let retainedTier = detail?.serviceTier.flatMap { tier in
            (option.serviceTiers ?? []).contains(where: { $0.id == tier }) || option.defaultServiceTier == tier ? tier : nil
        }
        let fields: [String: Any] = ["model": option.id, "effort": chosen as Any? ?? NSNull(),
                                     "serviceTier": retainedTier as Any? ?? NSNull()]
        if await save(fields) { RememberedModels.save(family, model: option.id, effort: chosen) }
    }
    private func chooseSpeed(_ tier: String, model selected: BotOptions.Model) async {
        var fields: [String: Any] = ["serviceTier": tier]
        if detail?.model == nil {
            fields["model"] = selected.id
            fields["effort"] = effort as Any? ?? NSNull()
        }
        _ = await save(fields)
    }
    @discardableResult private func save(_ fields: [String: Any]) async -> Bool {
        guard !fields.isEmpty, !saving else { return false }
        let scope = model.assignmentScope
        model.savingComposerSettings.insert(chat.id); failure = nil
        defer { if scope == model.assignmentScope { model.savingComposerSettings.remove(chat.id) } }
        do { try await library.updateConversation(chat.id, fields: fields); return true }
        catch { failure = managementError(error); return false }
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
    @State private var copied = false
    private var detail: ProjectConversationDetail? { library.details[chat.id] }
    var body: some View {
        NavigationStack {
            Form {
                if let detail {
                    Section {
                        TextField("Thread name", text: $title).submitLabel(.done)
                            .onSubmit { Task { await save(["title": title]) } }
                        Toggle("Pin thread", isOn: Binding(get: { self.detail?.isPinned ?? false }, set: { value in Task { await save(["isPinned": value]) } }))
                            .accessibilityIdentifier("project-thread-pin")
                    }
                    Section("Project") {
                        LabeledContent("Project", value: detail.projectName)
                        LabeledContent("Agent") {
                            HStack(spacing: 6) { ProviderIcon(family: detail.family, size: 16); Text(detail.family.title) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Working folder").font(.subheadline)
                            Text(detail.workingFolder).font(.footnote.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        }
                        if !detail.folderInProject {
                            Text("This folder is no longer part of the project. Add it back in project settings to continue here.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if let notice = detail.notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    }
                    Section("Continue on Mac") {
                        if let option = continuation?.options.first {
                            HStack(spacing: 12) {
                                Text(option.command).font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityLabel("Command to continue on your Mac")
                                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                                    UIPasteboard.general.string = option.command
                                    copied = true
                                }
                                .buttonStyle(.borderless).labelStyle(.titleAndIcon).font(.subheadline)
                                .accessibilityIdentifier("copy-continuation-" + option.id)
                            }
                            .task(id: copied) {
                                guard copied else { return }
                                try? await Task.sleep(for: .seconds(2))
                                if !Task.isCancelled { copied = false }
                            }
                        } else if let continuationFailure {
                            Text(continuationFailure).foregroundStyle(.secondary)
                        } else { ProgressView() }
                    }
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
        do {
            try await library.updateConversation(chat.id, fields: fields)
            if fields["isPinned"] != nil { await library.refresh() }
        }
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
                                // Only the name opens the editor; a row-wide tap
                                // gesture swallowed taps meant for the switch.
                                Button { editing = project } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "folder").foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(project.name).foregroundStyle(.primary)
                                            Text(project.folders.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Edits this project")
                                if busy.contains(project.id) { ProgressView() }
                                Toggle("Show in sidebar", isOn: Binding(get: { project.isIncluded }, set: { value in Task { await set(project, ["isIncluded": value]) } }))
                                    .labelsHidden()
                                    .disabled(busy.contains(project.id))
                                    .accessibilityLabel("Show \(project.name) in sidebar")
                                    .accessibilityIdentifier("project-include:" + project.id)
                            }
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
