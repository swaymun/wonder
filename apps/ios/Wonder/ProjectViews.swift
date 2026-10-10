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
    @Environment(\.wonderTheme) private var theme
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
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 10).frame(minHeight: 28)
            .background(theme.accent.opacity(0.12), in: Capsule())
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
        Menu {
            ForEach(ProjectAccessChoice.choices(family: family, supportsModes: supportsModes, current: access)) { choice in
                row(choice, isSelected: choice == selected)
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

/// Compact title with the project name. Threads can switch providers, so only
/// VoiceOver names the current one.
struct ProjectConversationHeader: View {
    let detail: ProjectConversationDetail
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                // A wide window has room for one thin line: title, then project.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(detail.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(detail.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                .frame(maxWidth: 420)
            } else {
                VStack(spacing: 1) {
                    Text(detail.title).font(.headline).lineLimit(1)
                    if !dynamicTypeSize.isAccessibilitySize {
                        Text(detail.projectName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: 240)
            }
        }
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

/// Model, effort and access for one project thread. The picker lists both
/// providers' models. A model of the thread's own provider is saved on the
/// thread; one of the other provider is carried by the next message, and the
/// Mac moves the thread to that provider when the message is delivered.
struct ProjectComposerSettings: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let chat: ChatSummary
    @State private var showingModel = false
    @State private var failure: String?
    private var detail: ProjectConversationDetail? { library.details[chat.id] }
    private var saving: Bool { model.savingComposerSettings.contains(chat.id) }
    private var pending: ProjectMessageModel? { model.projectNextModels[chat.id] }
    private var allModels: [BotOptions.Model] { (library.options?.models ?? []).filter { !$0.hidden } }
    private var groups: [ProjectModelGroup] {
        guard let detail else { return [] }
        return ProjectModelPicker.groups(models: allModels, current: detail.family)
    }
    /// The provider the next message goes to.
    private var targetFamily: AgentFamily? { pending?.family ?? detail?.family }
    private var models: [BotOptions.Model] { allModels.filter { $0.family == targetFamily } }
    /// A thread that never chose a model uses its provider's default.
    private var selected: BotOptions.Model? {
        guard let detail else { return nil }
        if let pending { return models.first { $0.id == pending.model } }
        if let stored = detail.model { return models.first { $0.id == stored } }
        return ModelDefaults.defaultModel(in: models)
    }
    private var effort: String? { selected.flatMap { ModelDefaults.effort(pending?.effort ?? detail?.effort, for: $0) } }
    private var serviceTier: String? { pending == nil ? detail?.serviceTier : pending?.serviceTier }
    private var title: String {
        if let selected {
            let summary = ModelDefaults.summary(model: selected, effort: effort)
            let speed = selected.serviceTiers?.first { $0.id == serviceTier }
            return speed.map { $0.id == "default" ? summary : summary + " · " + $0.label } ?? summary
        }
        return pending?.model ?? detail?.model ?? "Model"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                accessMenu
                Spacer(minLength: 0)
                Button { showingModel = true } label: { ComposerModelLabel(family: targetFamily, title: title) }
                    .disabled(saving || detail == nil)
                    .accessibilityLabel("Model").accessibilityValue(title)
                    .accessibilityIdentifier("project-composer-model")
            }
            if saving { ProgressView("Saving…").font(.caption).padding(.horizontal, 12) }
            if let failure { FailureDetails("Settings not saved", message: failure).padding(.horizontal, 12) }
        }
        .task(id: model.assignmentScope + ":" + String(model.macConnected == true)) { await library.loadOptions() }
        // The choice ends once the Mac has moved the thread to it.
        .onChange(of: detail) { _, latest in
            if let pending, ProjectModelPicker.isApplied(pending, to: latest) { model.projectNextModels[chat.id] = nil }
        }
        .sheet(isPresented: $showingModel) {
            NavigationStack {
                Form {
                    if groups.isEmpty {
                        Section("Model") { Text("Models are unavailable. Check \(model.macName).").foregroundStyle(.secondary) }
                    }
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.models) { option in
                                Button { Task { await choose(option) } } label: {
                                    HStack { Text(option.displayName); Spacer(); if option.id == selected?.id && option.family == targetFamily { Image(systemName: "checkmark") } }
                                }.foregroundStyle(.primary)
                                    .accessibilityIdentifier("project-model:\(option.id)")
                            }
                        } header: {
                            Text(group.family.title)
                        } footer: {
                            if group.family != detail?.family, let note = group.note { Text(note) }
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
                                        if option.id == (serviceTier ?? "default") { Image(systemName: "checkmark") }
                                    }
                                }
                                .accessibilityIdentifier("project-speed:\(option.id)")
                            }
                        }
                    }
                    if let failure { FailureDetails("Settings not saved", message: failure) }
                }
                .wonderGroupedStyle()
                .disabled(saving || model.accessEnded)
                .pinnedSheetHeader("Model") { showingModel = false }
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
        guard let detail else { return }
        // Choosing the current model again keeps the effort already chosen.
        guard effort != nil || option.id != selected?.id || option.family != targetFamily else { return }
        let chosen = effort ?? ModelDefaults.effort(for: option)
        let carriedTier = serviceTier.flatMap { tier in
            (option.serviceTiers ?? []).contains(where: { $0.id == tier }) || option.defaultServiceTier == tier ? tier : nil
        }
        switch ProjectModelPicker.choice(current: detail.family, option: option, effort: chosen, serviceTier: option.family == targetFamily ? carriedTier : nil) {
        case .sendWithNextMessage(let carried):
            // Nothing changes on the Mac yet; the next message carries this choice.
            failure = nil
            model.projectNextModels[chat.id] = carried
            RememberedModels.save(option.family, model: option.id, effort: chosen)
        case .saveToThread:
            let fields: [String: Any] = ["model": option.id, "effort": chosen as Any? ?? NSNull(),
                                         "serviceTier": carriedTier as Any? ?? NSNull()]
            if await save(fields) {
                model.projectNextModels[chat.id] = nil
                RememberedModels.save(detail.family, model: option.id, effort: chosen)
            }
        }
    }
    private func chooseSpeed(_ tier: String, model selected: BotOptions.Model) async {
        if var carried = pending {
            carried.serviceTier = tier
            model.projectNextModels[chat.id] = carried
            return
        }
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
                        Toggle("Pin thread", isOn: Binding(get: { self.detail?.isPinned ?? false }, set: { value in Task { await save(["isPinned": value]) } })).systemSwitch()
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
            .wonderGroupedStyle()
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

// MARK: - Archived threads

/// A Project's archived threads with Restore. Codex threads are archived in
/// Codex itself (from Wonder or the Codex app); Claude Code threads are hidden
/// in Wonder only, and their sessions stay in Claude Code on the Mac.
struct ArchivedThreadsView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let projectID: String
    let projectName: String
    @Environment(\.dismiss) private var dismiss
    @State private var page: ArchivedProjectThreadsPage?
    @State private var loadFailure: String?
    @State private var restoring: String?
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            List {
                if let page {
                    if page.threads.isEmpty {
                        Text("No archived threads in \(projectName).").foregroundStyle(.secondary)
                            .accessibilityIdentifier("archived-threads-empty")
                    }
                    ForEach(page.threads) { thread in row(thread) }
                    if !page.partial.isEmpty {
                        Text(page.partial.map(\.detail).joined(separator: " "))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section {
                    } footer: {
                        Text("Restoring a Codex thread restores it in Codex too. Claude Code threads are archived in Wonder only; Claude Code on your Mac still shows them.")
                    }
                } else if let loadFailure {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(loadFailure).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }
                            .accessibilityIdentifier("archived-threads-retry")
                    }
                } else {
                    ProgressView("Loading archived threads…").frame(maxWidth: .infinity)
                }
                if let failure { FailureDetails(message: failure) }
            }
            .wonderGroupedStyle()
            .navigationTitle("Archived threads").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("archived-threads-done") }
            .task { await load() }
            .refreshable { await load() }
        }
    }

    private func row(_ thread: ProjectThreadSummary) -> some View {
        HStack(spacing: 10) {
            Image(thread.family == .claude ? "ProviderClaude" : "ProviderCodex").resizable().scaledToFit()
                .frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title).lineLimit(2)
                Text(thread.family == .claude ? "Archived in Wonder" : "Archived in Codex")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if restoring == thread.reference {
                ProgressView().accessibilityLabel("Restoring")
            } else {
                Button("Restore") { restore(thread) }
                    .buttonStyle(.bordered)
                    .disabled(restoring != nil || model.macConnected != true)
                    .accessibilityLabel("Restore \(thread.title)")
                    .accessibilityIdentifier("restore-thread:" + thread.reference)
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("archived-thread:" + thread.reference)
    }

    private func load() async {
        loadFailure = nil
        do { page = try await library.archivedThreads(projectID) }
        catch is CancellationError {}
        catch { if page == nil { loadFailure = "Archived threads couldn’t be loaded. Check \(model.macName) and try again." } }
    }

    private func restore(_ thread: ProjectThreadSummary) {
        restoring = thread.reference; failure = nil
        Task {
            defer { restoring = nil }
            do {
                try await library.unarchive(projectID, thread: thread)
                if let current = page {
                    page = ArchivedProjectThreadsPage(threads: current.threads.filter { $0.reference != thread.reference },
                                                      partial: current.partial)
                }
            } catch is CancellationError {
            } catch {
                failure = "The thread couldn’t be restored. " + managementError(error)
            }
        }
    }
}

// MARK: - Project library

/// Create or edit a named group of folders on one Mac. Saving is metadata only.
struct ProjectEditorView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    let project: ProjectSummary?
    /// Pushed inside Add project, which owns the navigation stack and dismissal.
    var embedded = false
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
        if embedded { form } else { NavigationStack { form } }
    }
    private var form: some View {
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
            .wonderGroupedStyle()
            .disabled(saving || frozen)
            .navigationTitle(project == nil ? "Existing folder" : "Edit project").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
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
            .task {
                // Adding an existing folder starts by choosing it.
                if embedded, project == nil, folders.isEmpty { browsing = true }
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
            if !embedded { dismiss() }
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
                                Toggle("Show in sidebar", isOn: Binding(get: { project.isIncluded }, set: { value in Task { await set(project, ["isIncluded": value]) } })).systemSwitch()
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
                        Text("Hidden projects keep their threads on your Mac. Add projects from the sidebar.")
                    }
                }
                if let failure { FailureDetails(message: failure) }
            }
            .wonderGroupedStyle()
            .searchable(text: $search, prompt: "Search projects")
            .navigationTitle("Projects on \(model.macName)").navigationBarTitleDisplayMode(.inline)
            .refreshable { await library.refresh() }
            .task { await library.refresh() }
            .sheet(item: $editing) { project in ProjectEditorView(model: model, library: library, project: project) }
    }
    private func set(_ project: ProjectSummary, _ fields: [String: Any]) async {
        busy.insert(project.id); failure = nil
        defer { busy.remove(project.id) }
        do { _ = try await library.update(project.id, fields: fields) }
        catch { failure = managementError(error) }
    }
}

/// The one way to add a project on a Mac: create a new folder, choose an
/// existing one, or add a folder Codex or Claude Code already works in.
/// Suggestions are never added until the owner taps Add.
struct AddProjectView: View {
    @Environment(\.wonderTheme) private var theme
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    var onAdded: (ProjectSummary) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    private enum Step: Hashable { case newFolder, existingFolder }
    @State private var path: [Step] = []
    @State private var candidates: [ProjectCandidate] = []
    @State private var partial: [ProjectPartialFailure] = []
    @State private var loading = true
    @State private var loadFailure: String?
    @State private var adding: String?
    @State private var added: Set<String> = []
    @State private var addFailure: String?
    @State private var requestIDs: [String: String] = [:]

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: Step.newFolder) {
                        choice("New folder", detail: library.supportsNewFolder
                               ? "Create an empty folder on \(model.macName) for a new project."
                               : "Update Wonder on \(model.macName) to create folders from here.",
                               icon: "folder.badge.plus")
                    }
                    .disabled(!library.supportsNewFolder)
                    .accessibilityIdentifier("add-project-new-folder")
                    NavigationLink(value: Step.existingFolder) {
                        choice("Existing folder", detail: "Choose a folder that’s already on \(model.macName).", icon: "folder")
                    }
                    .accessibilityIdentifier("add-project-existing-folder")
                }
                Section {
                    ForEach(candidates.filter { !$0.isIncluded || added.contains($0.id) }) { candidate in
                        suggestion(candidate)
                    }
                    if loading { ProgressView("Looking for projects…") }
                    else if let loadFailure {
                        Text(loadFailure).foregroundStyle(.secondary)
                        Button("Try again") { Task { await load() } }
                    } else if candidates.allSatisfy(\.isIncluded) && added.isEmpty {
                        Text("No other folders found.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("add-project-no-suggestions")
                    }
                    ForEach(partial, id: \.self) { item in Text(item.detail).font(.footnote).foregroundStyle(.secondary) }
                    if let addFailure {
                        Text(addFailure).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("add-project-failure")
                    }
                } header: {
                    Text("Used by Codex or Claude Code")
                }
            }
            .wonderGroupedStyle()
            .navigationTitle("Add project").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(added.isEmpty ? "Cancel" : "Done") { dismiss() }.accessibilityIdentifier("add-project-close")
                }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .newFolder:
                    NewFolderProjectForm(model: model, library: library) { finish($0) }
                case .existingFolder:
                    ProjectEditorView(model: model, library: library, project: nil, embedded: true) { finish($0) }
                }
            }
            .task { await load() }
        }
    }
    private func choice(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
    private func suggestion(_ candidate: ProjectCandidate) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).foregroundStyle(.primary)
                Text(candidate.folders.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Text(candidate.sources.map(\.title).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if added.contains(candidate.id) {
                Label("Added", systemImage: "checkmark").labelStyle(.iconOnly).foregroundStyle(theme.accent)
                    .accessibilityLabel("Added")
            } else if adding == candidate.id {
                ProgressView().accessibilityLabel("Adding")
            } else {
                Button("Add") { Task { await add(candidate) } }
                    .buttonStyle(.bordered).disabled(adding != nil)
                    .accessibilityLabel("Add \(candidate.name)")
                    .accessibilityIdentifier("add-project-suggestion:" + candidate.name)
            }
        }
        .accessibilityElement(children: .contain)
    }
    private func finish(_ project: ProjectSummary) {
        onAdded(project)
        dismiss()
    }
    private func load() async {
        loading = true; loadFailure = nil
        defer { loading = false }
        do {
            let response = try await library.candidates()
            candidates = response.candidates; partial = response.partial
        } catch PairingFailure.response(404) {
            loadFailure = "Update Wonder on \(model.macName) to see suggestions."
        } catch is CancellationError {
            return
        } catch { loadFailure = "Suggestions couldn’t be loaded. You can still choose a folder." }
    }
    private func add(_ candidate: ProjectCandidate) async {
        adding = candidate.id; addFailure = nil
        defer { adding = nil }
        let request = requestIDs[candidate.id] ?? UUID().uuidString.lowercased()
        requestIDs[candidate.id] = request
        do {
            let project = try await library.createProject(requestID: request, name: candidate.name, folders: candidate.folders, primaryIndex: 0)
            added.insert(candidate.id)
            onAdded(project)
        } catch PairingFailure.hostMessage(_, let message) {
            addFailure = message
        } catch {
            addFailure = "\(candidate.name) couldn’t be added. \(managementError(error))"
        }
    }
}

/// A project in a folder created for it. The folder takes the project's name.
struct NewFolderProjectForm: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var library: ProjectLibrary
    var onCreated: (ProjectSummary) -> Void
    @State private var name = ""
    /// nil is the Mac's home folder.
    @State private var parent: String?
    @State private var parentChosen = false
    @State private var browsing = false
    @State private var saving = false
    @State private var failure: String?
    @State private var requestID = UUID().uuidString.lowercased()
    @FocusState private var nameFocused: Bool
    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameProblem: String? {
        if trimmed.hasPrefix(".") { return "Folder names can’t start with a period." }
        if trimmed.contains("/") || trimmed.contains(":") { return "Folder names can’t contain / or :." }
        if trimmed.count > 120 { return "Use a shorter name." }
        return nil
    }
    private var canCreate: Bool { !trimmed.isEmpty && nameProblem == nil && !saving && !model.accessEnded }
    private var locationName: String { parent.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Home folder" }
    var body: some View {
        Form {
            Section {
                TextField("Project name", text: $name)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { if canCreate { Task { await create() } } }
                    .accessibilityIdentifier("new-folder-name")
            } footer: {
                if let nameProblem { Text(nameProblem).foregroundStyle(.red) }
                else { Text("The folder gets the same name.") }
            }
            Section {
                Button { browsing = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(locationName).foregroundStyle(.primary)
                            if let parent {
                                Text(parent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        Spacer()
                        Text("Change").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Location, \(locationName)")
                .accessibilityHint("Chooses where the folder is created")
                .accessibilityIdentifier("new-folder-location")
            } header: { Text("Location on \(model.macName)") }
            if let failure {
                Section { Text(failure).foregroundStyle(.secondary).accessibilityIdentifier("new-folder-failure") }
            }
        }
        .wonderGroupedStyle()
        .disabled(saving)
        .navigationTitle("New folder").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving { ProgressView() }
                else { Button("Create") { Task { await create() } }.disabled(!canCreate).accessibilityIdentifier("new-folder-create") }
            }
        }
        .sheet(isPresented: $browsing) {
            MacLocationBrowser(model: model, title: "Location", foldersOnly: true) { path, isDirectory in
                guard isDirectory else { return }
                parent = path; parentChosen = true
            }
        }
        // A changed name or location is a different request.
        .onChange(of: trimmed) { _, _ in requestID = UUID().uuidString.lowercased() }
        .onChange(of: parent) { _, _ in requestID = UUID().uuidString.lowercased() }
        .onAppear {
            // New projects usually sit beside the most recent one.
            if !parentChosen, let recent = SidebarProjection.sorted(library.projects).first,
               let primary = recent.folders.first(where: \.isPrimary) ?? recent.folders.first {
                parent = URL(fileURLWithPath: primary.path).deletingLastPathComponent().path
            }
            nameFocused = true
        }
    }
    private func create() async {
        saving = true; failure = nil
        defer { saving = false }
        do {
            onCreated(try await library.createProject(requestID: requestID, name: trimmed, newFolderParent: parent))
        } catch PairingFailure.hostMessage(_, let message) {
            failure = message
        } catch is CancellationError {
            return
        } catch { failure = managementError(error) }
    }
}
