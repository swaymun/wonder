import SwiftUI
import AVKit
import ImageIO
import PhotosUI
import WonderPairing
import UniformTypeIdentifiers
import PDFKit
import WebKit

struct FailureDetails: View {
    let title: String
    let message: String
    init(_ title: String = "Action failed", message: String) {
        self.title = title
        self.message = message
    }
    var body: some View {
        DisclosureGroup {
            Text(message).font(.caption).foregroundStyle(.secondary)
        } label: {
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.tint(.secondary)
    }
}

/// The receipt of the latest row while its end is inside the viewport. The row
/// reports visibility rather than its frame, so scrolling changes the
/// scroller's state only when visibility flips, not on every frame.
private struct LatestReadVisibilityKey: PreferenceKey {
    static var defaultValue: VisibleReadReceipt? { nil }
    static func reduce(value: inout VisibleReadReceipt?, nextValue: () -> VisibleReadReceipt?) { if let next = nextValue() { value = next } }
}
private struct ConversationReadViewportKey: EnvironmentKey {
    static let defaultValue: CGRect = .zero
}
private struct ConversationInitialTargetKey: EnvironmentKey {
    static let defaultValue: String? = nil
}
private struct ConversationPositionReadyKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    fileprivate var conversationReadViewport: CGRect {
        get { self[ConversationReadViewportKey.self] }
        set { self[ConversationReadViewportKey.self] = newValue }
    }
    fileprivate var conversationInitialTarget: String? {
        get { self[ConversationInitialTargetKey.self] }
        set { self[ConversationInitialTargetKey.self] = newValue }
    }
    fileprivate var conversationPositionReady: Bool {
        get { self[ConversationPositionReadyKey.self] }
        set { self[ConversationPositionReadyKey.self] = newValue }
    }
}
private struct InitialConversationTargetFrame: Equatable {
    let id: String
    let frame: CGRect
}
private struct InitialConversationTargetFrameKey: PreferenceKey {
    static var defaultValue: InitialConversationTargetFrame? { nil }
    static func reduce(value: inout InitialConversationTargetFrame?, nextValue: () -> InitialConversationTargetFrame?) {
        if let next = nextValue() { value = next }
    }
}
private struct VisibleConversationNodesKey: PreferenceKey {
    static var defaultValue: Set<String> { [] }
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}
private struct ConversationRowMarker: View {
    let id: String
    let receipt: VisibleReadReceipt?
    @Environment(\.conversationReadViewport) private var viewport
    @Environment(\.conversationInitialTarget) private var initialTarget
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: LatestReadVisibilityKey.self,
                value: ReadVisibility.latestEndIsVisible(frame: geometry.frame(in: .global), viewport: viewport) ? receipt : nil)
                .preference(key: VisibleConversationNodesKey.self,
                    value: geometry.frame(in: .global).intersects(viewport) ? [id] : [])
                .preference(key: InitialConversationTargetFrameKey.self,
                    value: initialTarget == id ? InitialConversationTargetFrame(id: id, frame: geometry.frame(in: .global)) : nil)
        }
    }
}
private struct BottomFrameKey: PreferenceKey {
    static var defaultValue: CGRect? { nil }
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { if let next = nextValue() { value = next } }
}
private struct ReadViewportKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        // Descendants without a measurement contribute the default value.
        // They must not erase the scroll view's actual visible bounds.
        if !next.isEmpty { value = next }
    }
}

private struct PhotoAttachmentPicker: ViewModifier {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @Binding var isPresented: Bool
    let scope: String?
    @State private var selection: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection, matching: .images, preferredItemEncoding: .compatible)
            .task(id: selection) {
                guard let photo = selection else { return }
                guard scope == model.assignmentScope else { selection = nil; return }
                await model.stagePhoto(photo, chat: chat)
                selection = nil
            }
    }
}

/// The list mounts this row when the reader approaches the beginning.
/// Each cursor loads once; failures expose recovery without a permanent paging button.
private struct OlderMessagesLoader: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let cursor: String
    @State private var failure: String?
    @State private var retry = 0
    @Environment(\.conversationPositionReady) private var positionReady
    var body: some View {
        Group {
            if let failure {
                Button { retry += 1 } label: {
                    Label(failure, systemImage: "arrow.clockwise")
                        .font(.footnote).frame(minHeight: 44)
                }.accessibilityLabel("Retry loading earlier messages")
            } else {
                ProgressView().accessibilityLabel("Loading earlier messages")
            }
        }
        .frame(maxWidth: .infinity).frame(minHeight: 28)
        .task(id: positionReady ? cursor + "-" + String(retry) : nil) {
            guard positionReady else { return }
            failure = nil
            while model.loadingConversationIDs.contains(chat.id) {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            failure = await model.loadOlder(chat)
        }
    }
}

/// Scroll position and geometry change frequently. Keep them below the view that
/// prepares the full message timeline and composer.
private struct ConversationScrollRequest: Equatable {
    let id: String
    var anchor: UnitPoint? = nil
    var animated = false
}

private struct ConversationScrollPosition: ViewModifier {
    @Binding var request: ConversationScrollRequest?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: request, initial: true) { _, value in
                    guard let value else { return }
                    let animate = value.animated && !reduceMotion
                    var transaction = Transaction(animation: animate ? .easeOut(duration: 0.2) : nil)
                    transaction.disablesAnimations = !animate
                    withTransaction(transaction) {
                        proxy.scrollTo(value.id, anchor: value.id == "conversation-bottom" ? .bottom : value.anchor)
                    }
                    request = nil
                }
        }
    }
}

// SwiftUI appearance runs during the navigation transition. Restore cached
// reading intent after UIKit has finished presenting the final scroll viewport.
private struct ConversationPresentationReady: UIViewControllerRepresentable {
    let onReady: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(onReady: onReady) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.onReady = onReady }
    final class Controller: UIViewController {
        var onReady: () -> Void
        init(onReady: @escaping () -> Void) { self.onReady = onReady; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            if let coordinator = transitionCoordinator, coordinator.isAnimated,
               coordinator.animate(alongsideTransition: nil, completion: { [weak self] context in
                   guard !context.isCancelled else { return }
                   self?.onReady()
               }) { return }
            onReady()
        }
    }
}

private struct ConversationScroller<Content: View>: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var projects: ProjectLibrary
    let chat: ChatSummary
    let entries: [ChatFeedEntry]
    let nodeIDs: [String]
    let isCovered: Bool
    @Binding var requestedScrollID: String?
    @ViewBuilder let content: Content
    @State private var position: String?
    @State private var scrollRequest: ConversationScrollRequest?
    @State private var restored = false
    @State private var initialTarget: String?
    @State private var presented = false
    @State private var visibleLatestReceipt: VisibleReadReceipt?
    @State private var readViewport: CGRect = .zero
    @State private var bottomVisible = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bottomID = "conversation-bottom"

    private var readingPosition: String? { restored ? (bottomVisible ? bottomID : position) : nil }
    private var waitingForPosition: Bool { !restored && !nodeIDs.isEmpty }

    private var visibleReadReceipt: VisibleReadReceipt? {
        guard restored, phase == .active, !model.previewMode, !model.accessEnded,
              !isCovered,
              model.macConnected == true, !model.cachedConversationIds.contains(chat.id),
              model.hasUnread(chat.id),
              !projects.manuallyUnread.contains(chat.id),
              let receipt = visibleLatestReceipt,
              receipt == model.readReceipt(for: chat.id) else { return nil }
        return receipt
    }

    private func restorePositionIfNeeded() {
        guard presented, !nodeIDs.isEmpty else { return }
        if restored {
            if let anchor = ChatFeedNode.survivingAnchor(for: position, entries: entries, nodeIDs: nodeIDs), anchor != position {
                scrollRequest = ConversationScrollRequest(id: anchor)
            }
            return
        }
        let focus = model.searchFocus.flatMap { $0.conversationID == chat.id ? $0.scrollID : nil }
        let saved = model.position(for: chat.id)
        var target: String?
        if let focus, nodeIDs.contains(focus) { target = focus }
        else if let saved, nodeIDs.contains(saved) { target = saved }
        else if let saved {
            target = entries.first { entry in
                entry.rows.contains { row in row.id == saved || saved.hasPrefix("file:" + row.id + ":") }
            }?.id
        }
        initialTarget = target ?? bottomID
        scrollRequest = ConversationScrollRequest(id: target ?? bottomID, anchor: .top)
        if initialTarget == bottomID && bottomVisible { restored = true }
    }

    var body: some View {
        Group {
            List {
                content
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            .accessibilityIdentifier("conversation-scroll")
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .buttonStyle(.borderless)
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .contentMargins(.vertical, 16, for: .scrollContent)
            .modifier(ConversationScrollPosition(request: $scrollRequest))
            .background { ConversationPresentationReady { presented = true }.frame(width: 0, height: 0).accessibilityHidden(true) }
            // Keyboard/rotation changes resize only the viewport; the latest
            // row re-evaluates its visibility against the new bounds.
            .environment(\.conversationReadViewport, readViewport)
            .environment(\.conversationInitialTarget, restored ? nil : initialTarget)
            .environment(\.conversationPositionReady, !waitingForPosition)
            .background { GeometryReader { geometry in Color.clear.preference(key: ReadViewportKey.self, value: geometry.frame(in: .global)) } }
            .onPreferenceChange(LatestReadVisibilityKey.self) { receipt in
                if visibleLatestReceipt != receipt { visibleLatestReceipt = receipt }
            }
            .onPreferenceChange(VisibleConversationNodesKey.self) { visibleIDs in
                if let first = nodeIDs.first(where: visibleIDs.contains), first != position { position = first }
            }
            .onPreferenceChange(ReadViewportKey.self) { viewport in
                if readViewport != viewport { readViewport = viewport }
            }
            .onPreferenceChange(InitialConversationTargetFrameKey.self) { target in
                guard !restored, let target, target.id == initialTarget, !readViewport.isEmpty else { return }
                let frame = target.frame
                let fits = frame.minY >= readViewport.minY - 1 && frame.maxY <= readViewport.maxY + 1
                let tallStartVisible = frame.height > readViewport.height && abs(frame.minY - readViewport.minY) <= 24
                if fits || tallStartVisible { restored = true }
            }
            .onPreferenceChange(BottomFrameKey.self) { frame in
                let visible = frame.map { $0.maxY <= readViewport.maxY + 24 && $0.maxY >= readViewport.minY } ?? false
                if bottomVisible != visible { bottomVisible = visible }
                if !restored, initialTarget == bottomID, visible { restored = true }
            }
            // A scroll request is not layout completion. Keep the real list
            // mounted but covered until its intended row/end is in the viewport.
            .opacity(waitingForPosition ? 0 : 1)
            .accessibilityHidden(waitingForPosition)
            .allowsHitTesting(!waitingForPosition)
            .overlay {
                if waitingForPosition {
                    ProgressView("Loading chat…")
                        .accessibilityIdentifier("conversation-loading")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .overlay(alignment: .bottom) {
                if restored && !bottomVisible && !entries.isEmpty {
                    Button {
                        #if WONDER_DIAGNOSTICS
                        Diagnostics.shared.interaction("scroll.bottom")
                        #endif
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            scrollRequest = ConversationScrollRequest(id: bottomID, animated: true)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(.primary)
                            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scroll to bottom")
                    .accessibilityIdentifier("scroll-to-bottom")
                    .padding(.bottom, 8)
                }
            }
            .task(id: presented ? nodeIDs : []) { restorePositionIfNeeded() }
            .onChange(of: model.searchFocus?.id) { _, _ in
                if let focus = model.searchFocus, focus.conversationID == chat.id { scrollRequest = ConversationScrollRequest(id: focus.scrollID) }
            }
            .onChange(of: requestedScrollID) { _, target in
                guard let target else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scrollRequest = ConversationScrollRequest(id: target, anchor: .top, animated: true) }
                requestedScrollID = nil
            }
            .onAppear {
                if let target = requestedScrollID {
                    scrollRequest = ConversationScrollRequest(id: target, anchor: .top, animated: true)
                    requestedScrollID = nil
                }
            }
            .onDisappear { model.savePosition(readingPosition, chat: chat.id) }
            .task(id: readingPosition) {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                model.savePosition(readingPosition, chat: chat.id)
            }
            .onChange(of: phase) { _, next in
                if next != .active { model.savePosition(readingPosition, chat: chat.id) }
            }
            .task(id: visibleReadReceipt) {
                guard let receipt = visibleReadReceipt else { return }
                // A transient failure or concurrent list refresh must not leave
                // this stationary, visible message unread until the next scroll.
                // The receipt clears once the host confirms, ending the loop.
                var delay = 750
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                    guard visibleReadReceipt == receipt, !Task.isCancelled else { return }
                    await model.acknowledgeVisibleRead(receipt)
                    delay = min(delay * 2, 30_000)
                }
            }
        }
    }
}

// Native row insets provide the outer margin; wide layouts keep the readable
// content centered in a bounded column.
private struct ConversationColumn: ViewModifier {
    func body(content: Content) -> some View {
        content.frame(maxWidth: 768, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

private struct ComposerUsageMonitor: ViewModifier {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let readOnly: Bool
    @Environment(\.scenePhase) private var phase
    private var scope: String {
        [model.assignmentScope, chat.id, model.usageModel(chat), String(phase == .active)].joined(separator: ":")
    }
    func body(content: Content) -> some View {
        content.task(id: scope) {
            guard !readOnly, phase == .active else { return }
            while !Task.isCancelled {
                await model.refreshComposerUsage(chat)
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }
}

struct ConversationView: View {
    @State private var activityDisclosure = ActivityDisclosurePolicy.State()
    @State private var expandedDetails: Set<String> = []
    @State private var requestedScrollID: String?
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let rootChat: ChatSummary?
    let readOnly: Bool
    @State private var selectedSubagent: SubagentSummary?
    @State private var showingSubagents = false
    @State private var selectedProjectSubagent: ProjectSubagentSummary?
    @State private var showingProjectSubagents = false
    @State private var showingGoal = false
    @State private var showingComputer = false
    @State private var implementingPlan = false
    /// Mirrors the project library's plan mode and host support for this thread,
    /// so a change re-renders this view without observing the whole library.
    @State private var planModeOn: Bool
    @State private var supportsModes: Bool
    @State private var restoreSubagentRoster = false
    @State private var importing = false
    @State private var selectingPhoto = false
    @State private var showingCamera = false
    @State private var cameraScope: String?
    @State private var importScope: String?
    @State private var workspaceRequest: WorkspaceBrowserRequest?
    @State private var showingApps = false
    @State private var showingDetails = false
    @State private var showingUsage = false
    @State private var composerPhoto: ComposerAttachment?
    @State private var annotationEdit: ComposerAttachment?
    @State private var imagePasteTask: Task<Void, Never>?
    @State private var messagePhotoGallery: MessagePhotoGallery?
    @State private var surfaceVisible = false
    @State private var avatarMotion = ScienceAvatarHeaderMotionReducer()
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct AttachmentMetadataRequest: Hashable {
        let chatID: String
        let scope: String
        let ids: [String]
    }
    private var cameraContextToken: String {
        model.cameraContextID.uuidString + ":" + chat.id
    }
    private var conversationCovered: Bool {
        showingDetails || showingApps || showingUsage || importing || selectingPhoto || showingCamera || composerPhoto != nil || messagePhotoGallery != nil || selectedSubagent != nil || showingSubagents || selectedProjectSubagent != nil || showingProjectSubagents || showingGoal || showingComputer
    }
    private var avatarMotionState: ScienceAvatarMotionState {
        guard let turnID = model.activeTurn(chat.id),
              let turn = model.turn(turnID, in: chat.id),
              turn.isInProgress else { return .idle }
        let activeStates = Set(["started", "streaming", "waiting"])
        guard let item = turn.items.last(where: { activeStates.contains($0.state) }) else { return .working }
        return item.type == "reasoning" ? .thinking : .working
    }
    private var avatarMotionSignal: ScienceAvatarHeaderMotionSignal {
        ScienceAvatarHeaderMotionSignal(
            activeTurnID: chat.botId == nil ? nil : model.activeTurn(chat.id),
            state: avatarMotionState,
            isPresented: chat.botId != nil && surfaceVisible && phase == .active && !conversationCovered && !lowPowerMode,
            reduceMotion: reduceMotion
        )
    }
    private var headerBot: ManagedBot? {
        guard let botID = chat.botId else { return nil }
        return model.managedBots.first { $0.id == botID }
    }
    private var pendingAttentionRequests: [AttentionRequest] {
        model.requests(for: chat).filter { !$0.isQuestion }
    }
    private func messageAttachments(for row: ReadRow, metadata: [String: ConversationFile]) -> [MessageAttachmentPresentation] {
        return row.attachmentIds.map { id in
            MessageAttachmentPresentation(id: id, file: metadata[id])
        }
    }
    init(
        model: ConnectionModel,
        chat: ChatSummary,
        rootChat: ChatSummary? = nil,
        readOnly: Bool = false
    ) {
        self.model = model
        self.chat = chat
        self.rootChat = rootChat
        self.readOnly = readOnly
        _planModeOn = State(initialValue: model.projects.details[chat.id]?.planMode == true)
        _supportsModes = State(initialValue: model.projects.supportsModes)
    }
    private func subagent(for row: ReadRow) -> SubagentSummary? {
        guard let item = row.item,
              item.type == "subAgentActivity" || item.type == "collabAgentToolCall" else { return nil }
        let threadID = item.payload?["agentThreadId"]?.string
            ?? item.payload?["receiverThreadIds"]?.array?.compactMap(\.string).first
        guard let threadID else { return nil }
        return model.subagents.values.lazy.flatMap { $0 }.first(where: { $0.threadId == threadID })
    }
    @ViewBuilder private func entryContent(
        _ entry: ChatFeedEntry,
        turns: [String: ReadTurn],
        previous: [String: ReadRow],
        latestActivityEntryIDs: Set<String>,
        latestActiveActivityEntryID: String?,
        expandedActivityIDs: Set<String>,
        attachmentMetadata: [String: ConversationFile],
        conversationImageFiles: [ConversationFile],
        implementablePlanID: String?
    ) -> some View {
                                if let status = entry.rows.first?.profileStatus {
                                    Label(status, systemImage: "pencil")
                                        .font(.footnote).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity)
                                        .accessibilityElement(children: .combine)
                                } else if entry.isActivity {
                                    ActivityGroupView(rows: entry.rows,
                                                      turn: entry.rows.first?.turnId.flatMap { turns[$0] },
                                                      isLatestSegmentForTurn: latestActivityEntryIDs.contains(entry.id),
                                                      isLatestActiveSegment: latestActiveActivityEntryID == entry.id,
                                                      isProjectConversation: model.isProject(chat),
                                                      expanded: expandedActivityIDs.contains(entry.id)) {
                                        toggleActivity(entry: entry, isExpanded: expandedActivityIDs.contains(entry.id))
                                    }
                                } else if let row = entry.rows.first, row.isPlan {
                                    PlanCard(text: row.planText, isRunning: row.activitySummary?.isRunning == true,
                                             canImplement: row.id == implementablePlanID, isImplementing: implementingPlan,
                                             implement: implementPlan)
                                        .frame(maxWidth: 640, alignment: .leading)
                                } else if let row = entry.rows.first, readOnly || !(model.asyncQuestions[chat.id] ?? []).contains(where: { $0.rowId == row.id }) {
                                if let question = row.nativeQuestion {
                                    NativeQuestionHistoryRow(question: question, rowID: row.id, author: row.author)
                                        .frame(maxWidth: 640, alignment: .leading)
                                } else {
                                let pending = model.composers[chat.id]?.pending
                                let speakerBot = row.authorId.flatMap { id in model.managedBots.first { $0.id == id } }
                                let messageAttachments = messageAttachments(for: row, metadata: attachmentMetadata)
                                MessageRow(row: row, isGroup: chat.botId == nil && !model.isProject(chat), showIdentity: SpeakerPresentation.showsIdentity(row: row, previous: previous[row.id], isGroup: chat.botId == nil && !model.isProject(chat)),
                                    pending: row.id == pending.map({ "user-" + $0.request.clientMessageId }) ? pending : nil,
                                    recoveredBeforeReconnect: model.composers[chat.id]?.recoveredPending?.contains(where: { row.id == "user-" + $0.request.clientMessageId }) == true,
                                    isSending: model.sending.contains(chat.id),
                                    canRetry: !readOnly && !model.accessEnded && !model.previewMode,
                                    retry: { Task { await model.deliver(chat) } },
                                    attachments: messageAttachments,
                                    imagePreviews: model.imagePreviews,
                                    imagePreviewScope: model.imagePreviewScope,
                                    chatID: chat.id,
                                    loadRemoteData: { [model, chat] file in try await model.download(file, chat: chat) },
                                    openImage: { file in
                                        guard let id = file.file?.id else { return }
                                        messagePhotoGallery = MessagePhotoGallery(
                                            files: conversationImageFiles,
                                            initialFileID: id
                                        )
                                    },
                                    openDocument: { workspaceRequest = WorkspaceBrowserRequest(attachmentIDs: row.attachmentIds) },
                                    avatarColor: speakerBot?.avatarColor, avatarShape: speakerBot?.avatarShape, avatarPalette: speakerBot?.avatarPalette)
                                }
                                }
    }
    private func toggleActivity(entry: ChatFeedEntry, isExpanded: Bool) {
        guard let turnID = entry.rows.first?.turnId else { return }
        let activeTurnIDs = model.activeTurnIDs(chat.id)
        let lifecycle = ActivityDisclosurePolicy.lifecycle(for: model.turn(turnID, in: chat.id))
        let descriptor = ActivityDisclosurePolicy.Entry(
            conversationID: chat.id,
            turnID: turnID,
            entryID: entry.id,
            lifecycle: lifecycle,
            autoOpenWhileActive: activeTurnIDs.contains(turnID)
        )
        #if WONDER_DIAGNOSTICS
        Diagnostics.shared.interaction("activity.expand", count: isExpanded ? 0 : 1)
        #endif
        activityDisclosure = ActivityDisclosurePolicy.toggled(activityDisclosure, entry: descriptor, isExpanded: isExpanded)
        // The tapped row is already visible. A forced animated scroll on every
        // disclosure change repeatedly lays out long histories and moves the
        // reader away from the row they opened.
    }
    private func toggleDetail(_ id: String) {
        #if WONDER_DIAGNOSTICS
        Diagnostics.shared.interaction("detail.expand", count: expandedDetails.contains(id) ? 0 : 1)
        #endif
        if !expandedDetails.insert(id).inserted { expandedDetails.remove(id) }
        requestedScrollID = "activity:" + id
    }
    private func settledQuestions(for entry: ChatFeedEntry, timeline: [ReadRow]) -> [AsyncQuestion] {
        (model.asyncQuestions[chat.id] ?? []).filter { question in
            guard !question.canAnswer(now: UInt64(Date().timeIntervalSince1970 * 1000)) else { return false }
            if entry.rows.contains(where: { $0.id == question.rowId }) { return true }
            guard !timeline.contains(where: { $0.id == question.rowId }),
                  let anchor = timeline.last(where: { $0.turnId == question.turnId }) else { return false }
            return entry.rows.contains(where: { $0.id == anchor.id })
        }
    }
    private func answeredQuestionsOutsideTimeline(_ timeline: [ReadRow]) -> [AsyncQuestion] {
        guard model.asyncQuestions[chat.id]?.contains(where: { $0.state == "answered" }) == true else { return [] }
        let rowIDs = Set(timeline.map(\.id))
        let turnIDs = Set(timeline.compactMap(\.turnId))
        return (model.asyncQuestions[chat.id] ?? []).filter { question in
            question.state == "answered" && !rowIDs.contains(question.rowId) && !turnIDs.contains(question.turnId)
        }
    }
    private func firstExpandableActivity(in entries: [ChatFeedEntry]) -> ReadRow? {
        for entry in entries where entry.isActivity {
            if let row = entry.rows.first(where: { row in
                row.activitySummary != nil && row.item?.type != "reasoning" && !row.isPlan
            }) {
                return row
            }
        }
        return nil
    }
    @ViewBuilder private func activityContent(_ row: ReadRow) -> some View {
        if row.isCommentary {
            BotMessageText(text: row.text)
                .modifier(ChatBubbleSurface())
                .frame(maxWidth: 640, alignment: .leading)
                .accessibilityLabel(row.author + ": " + row.text)
        } else {
            ActivityItemView(
                row: row,
                expanded: expandedDetails.contains(row.id),
                subagent: subagent(for: row),
                openSubagent: { selectedSubagent = $0 },
                openFile: { path in workspaceRequest = WorkspaceBrowserRequest(initialFilePath: path) },
                toggle: { toggleDetail(row.id) }
            )
        }
    }
    @ViewBuilder private func groupWork(for row: ReadRow?) -> some View {
        if let row, row.isUser, let group = model.groups[chat.id],
           let message = group.messages.first(where: { "user-" + ($0.clientMessageId ?? $0.messageId) == row.id }),
           let run = group.collaboration?.runs.first(where: { $0.parentMessageId == message.messageId }) {
            GroupWorkView(model: model, group: group, run: run, openFile: { path in workspaceRequest = WorkspaceBrowserRequest(initialFilePath: path) })
        }
    }
    /// A plan-mode thread offers to implement its newest finished plan once the
    /// agent is idle and the composer has nothing in progress.
    private func planToImplement(in timeline: [ReadRow]) -> String? {
        guard !readOnly, supportsModes, model.isProject(chat), planModeOn, model.activeTurn(chat.id) == nil else { return nil }
        let intent = model.composers[chat.id]
        guard (intent?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (intent?.attachmentCount ?? 0) == 0, intent?.pending == nil else { return nil }
        return ReadRow.implementablePlanID(in: timeline)
    }
    /// Leaves plan mode, then sends the plan for implementation. If the save
    /// fails the composer reports it and nothing is sent.
    private func implementPlan() {
        guard !implementingPlan else { return }
        implementingPlan = true
        let scope = model.assignmentScope
        Task {
            defer { implementingPlan = false }
            guard await setPlanMode(false, model: model, library: model.projects, chat: chat),
                  !Task.isCancelled, scope == model.assignmentScope, model.visibleChat?.id == chat.id,
                  model.activeTurn(chat.id) == nil else { return }
            let intent = model.composers[chat.id]
            guard (intent?.draft ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (intent?.attachmentCount ?? 0) == 0, intent?.pending == nil else { return }
            model.editDraft("Implement the plan.", chat: chat.id)
            await model.send(chat)
        }
    }
    /// Project history belongs to the provider, so it is re-read alongside the
    /// saved copy that is already on screen. Send waits for the re-read.
    private func refreshNativeHistory() async {
        if model.isProject(chat), !readOnly { await model.reloadNativeHistory(chat) }
    }
    var body: some View {
        #if WONDER_DIAGNOSTICS
        let timelineStart = ProcessInfo.processInfo.systemUptime
        #endif
        let prepared = workspaceRequest == nil
            ? model.timeline(for: chat, focusedRowID: model.searchFocus?.conversationID == chat.id ? model.searchFocus?.rowID : nil)
            : ConversationTimeline(chatID: chat.id, rows: [], activeTurnIDs: [],
                                   activeTurnID: nil, focusedRowID: nil, turns: nil)
        let timeline = prepared.rows
        let attachmentMetadata = Dictionary((model.files[chat.id] ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let conversationImageFiles = ConversationAttachmentGallery.imageFiles(model.files[chat.id] ?? [])
        let requestedAttachmentIDs = Array(Set(
            prepared.attachmentIDs
                + (model.queues[chat.id] ?? []).flatMap(\.attachmentIds)
                + (model.composers[chat.id]?.draftAttachmentIds ?? [])
        )).sorted()
        let attachmentMetadataRequest = AttachmentMetadataRequest(
            chatID: chat.id,
            scope: model.assignmentScope,
            ids: requestedAttachmentIDs
        )
        let previous = prepared.previous
        let entries = prepared.entries
        let latestActivityEntryIDs = prepared.latestActivityEntryIDs
        let latestActiveActivityEntryID = prepared.latestActiveActivityEntryID
        let disclosureEntries = prepared.disclosureEntries
        let retainedTurnIDs = prepared.retainedTurnIDs
        let reconciledDisclosure = ActivityDisclosurePolicy.reconciled(
            activityDisclosure,
            entries: disclosureEntries,
            retainedConversationID: chat.id,
            retainedTurnIDs: retainedTurnIDs
        )
        let searchReveal: Set<ActivityDisclosurePolicy.Key> = {
            guard let focus = model.searchFocus, focus.conversationID == chat.id,
                  let entry = entries.first(where: { $0.rows.contains(where: { $0.id == focus.rowID }) }),
                  let turnID = entry.rows.first?.turnId else { return [] }
            return [ActivityDisclosurePolicy.Key(conversationID: chat.id, turnID: turnID, entryID: entry.id)]
        }()
        let expandedActivityIDs = ActivityDisclosurePolicy.expandedEntryIDs(
            entries: disclosureEntries,
            state: reconciledDisclosure,
            searchReveal: searchReveal
        )
        let nodes = ChatFeedNode.visible(entries, expanded: expandedActivityIDs)
        let answeredQuestions = answeredQuestionsOutsideTimeline(timeline)
        let disclosureRevision = disclosureEntries
        let implementablePlanID = planToImplement(in: timeline)
        #if WONDER_DIAGNOSTICS
        if workspaceRequest == nil {
            let _ = DiagnosticJournal.shared.record(DiagnosticEvent(operation: "timeline.prepare", durationMs: (ProcessInfo.processInfo.systemUptime - timelineStart) * 1000, count: UInt64(timeline.count)))
        }
        #endif
        Group {
            if let request = workspaceRequest {
                WorkspaceBrowser(model: model, chat: chat, attachmentIDs: request.attachmentIDs,
                                 initialFilePath: request.initialFilePath, preferredRootID: request.preferredRootID,
                                 reanchor: request.reanchor, replacingAnnotationID: request.replacingAnnotationID,
                                 onClose: { workspaceRequest = nil })
                    .id(request.id)
            } else if model.snapshots[chat.id] != nil || model.groups[chat.id] != nil {
                ConversationScroller(model: model, projects: model.projects, chat: chat, entries: entries, nodeIDs: nodes.map(\.id),
                    isCovered: conversationCovered,
                    requestedScrollID: $requestedScrollID) {
                        Group {
                            if let cursor = model.snapshots[chat.id]?.thread.nextCursor {
                                OlderMessagesLoader(model: model, chat: chat, cursor: cursor)
                                    .modifier(ConversationColumn())
                            }
                            ForEach(readOnly ? [] : answeredQuestions) { q in
                                AsyncQuestionRow(model: model, chat: chat, question: q)
                                    .modifier(ConversationColumn())
                            }
                            ForEach(nodes) { node in
                                VStack(alignment: .leading, spacing: 12) {
                                switch node.content {
                                case .activity(let row):
                                    activityContent(row)
                                case .compaction(let row):
                                    ContextCompactionMarker(row: row)
                                case .file(let file): ToolFilePreview(model: model, chat: chat, file: file)
                                case .entry(let entry):
                                entryContent(
                                    entry,
                                    turns: prepared.turns,
                                    previous: previous,
                                    latestActivityEntryIDs: latestActivityEntryIDs,
                                    latestActiveActivityEntryID: latestActiveActivityEntryID,
                                    expandedActivityIDs: expandedActivityIDs,
                                    attachmentMetadata: attachmentMetadata,
                                    conversationImageFiles: conversationImageFiles,
                                    implementablePlanID: implementablePlanID
                                )
                                groupWork(for: entry.rows.first)
                                ForEach(readOnly ? [] : settledQuestions(for: entry, timeline: timeline)) { question in
                                    AsyncQuestionRow(model: model, chat: chat, question: question)
                                }
                                }
                                }.modifier(ConversationColumn()).id(node.id)
                                .accessibilityElement(children: .contain)
                                .background {
                                    ConversationRowMarker(id: node.id,
                                        receipt: node.id == nodes.last?.id ? model.readReceipt(for: chat.id) : nil)
                                }
                            }
                            VStack(alignment: .leading, spacing: 12) {
                            if !readOnly { QueueDock(
                                model: model,
                                chat: chat,
                                attachmentMetadata: attachmentMetadata,
                                imagePreviews: model.imagePreviews,
                                imagePreviewScope: model.imagePreviewScope,
                                loadRemoteData: { [model, chat] file in try await model.download(file, chat: chat) },
                                openImage: { attachment in
                                    guard let id = attachment.file?.id else { return }
                                    messagePhotoGallery = MessagePhotoGallery(
                                        files: conversationImageFiles,
                                        initialFileID: id
                                    )
                                },
                                openDocument: { ids in
                                    workspaceRequest = WorkspaceBrowserRequest(attachmentIDs: ids)
                                }
                            ).modifier(ConversationColumn()) }
                            // Folder changes are a direct-Bot capability. Group
                            // and child conversations use their own verified
                            // workspace boundaries and must not surface a
                            // coordinator's direct-Bot request card.
                            if let botID = chat.botId, !chat.isArchived, !model.isSubagent(chat), model.groups[chat.id] == nil {
                                FolderRequestsView(model: model, botID: botID)
                                    .modifier(ConversationColumn())
                            }
                            if !readOnly {
                            ForEach(model.subagents[chat.id] ?? []) { child in
                                let childChat = child.chatSummary(botId: chat.botId)
                                ForEach((model.asyncQuestions[child.id] ?? []).filter { $0.state == "pending" }) { question in
                                    AsyncQuestionRow(model: model, chat: childChat, question: question)
                                        .modifier(ConversationColumn())
                                }
                            }
                            ForEach(pendingAttentionRequests) { request in
                                AttentionRow(model: model, request: request).modifier(ConversationColumn()).id("approval-" + request.id)
                            }
                            }
                            Color.clear.frame(height: 1).modifier(ConversationColumn())
                                .background { GeometryReader { geometry in
                                    Color.clear.preference(key: BottomFrameKey.self, value: geometry.frame(in: .global))
                                } }
                            }.id("conversation-bottom")
                        }
                    }
            } else if let failure = model.conversationLoadFailures[chat.id] {
                ContentUnavailableView {
                    Label("Couldn’t load this chat", systemImage: "exclamationmark.bubble")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try again") { Task { await model.retryConversation(chat) } }
                        .accessibilityIdentifier("conversation-load-retry")
                }
            } else if model.isSubagent(chat), !model.loadingConversationIDs.contains(chat.id),
                      let error = model.subagentErrors[model.subagentSummary(for: chat.id)?.parentConversationId ?? ""] {
                ContentUnavailableView(chat.title, systemImage: "person.2", description: Text(error))
            } else if model.accessEnded || model.macConnected == false {
                ContentUnavailableView("Not saved on this device", systemImage: "wifi.slash",
                    description: Text("Connect to \(model.macName) to load this chat."))
            } else {
                // Connecting or loading: saved chats never reach this branch.
                ProgressView("Loading chat…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("conversation-loading")
            }
        }
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(chat.title)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onChange(of: disclosureRevision, initial: true) { _, _ in
            guard workspaceRequest == nil else { return }
            activityDisclosure = ActivityDisclosurePolicy.reconciled(
                activityDisclosure,
                entries: disclosureEntries,
                retainedConversationID: chat.id,
                retainedTurnIDs: retainedTurnIDs
            )
        }
        #if WONDER_DIAGNOSTICS
        .onAppear { if let saved = model.connection { Diagnostics.shared.selectHost(saved) }; Diagnostics.shared.interaction("chat.open") }
        .onReceive(DiagnosticScenarioControl.shared.$command) { command in
            guard let command, command.chatID == chat.id else { return }
            var performed = false
            switch command.action {
            case .expand:
                if let entry = entries.first(where: { $0.isActivity }) {
                    toggleActivity(entry: entry, isExpanded: expandedActivityIDs.contains(entry.id))
                    performed = true
                }
            case .detail:
                if let row = firstExpandableActivity(in: entries) {
                    toggleDetail(row.id)
                    performed = true
                }
            case .bottom: requestedScrollID="conversation-bottom"; performed=true
            case .top: requestedScrollID=nodes.first?.id; performed = !nodes.isEmpty
            }
            DiagnosticScenarioControl.shared.acknowledge(command.id, performed: performed)
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .principal) {
                if readOnly { conversationHeader }
                else { conversationTitleMenu }
            }
        }
        .sheet(isPresented: $showingDetails) {
            if model.isProject(chat) { ProjectConversationDetailsView(model: model, library: model.projects, chat: chat) }
            else { ConversationDetails(model: model, chat: chat) }
        }
        .fullScreenCover(isPresented: $showingComputer) {
            NavigationStack { ComputerSessionView(model: model, chat: chat) }
        }

        .sheet(isPresented: $showingApps) { NavigationStack { ConnectedAppsView(model: model, conversationId: chat.id).toolbar { Button("Done") { showingApps = false } } } }
        .sheet(isPresented: $showingUsage) { ProviderUsageView(model: model, family: model.agentFamily(chat)) }
        .modifier(PhotoAttachmentPicker(model: model, chat: chat, isPresented: $selectingPhoto, scope: importScope))
        .sheet(isPresented: $showingCamera, onDismiss: { cameraScope = nil }) {
            if let cameraScope {
                CameraCaptureView(
                    chatID: chat.id,
                    chatTitle: chat.title,
                    originatingScope: cameraScope,
                    currentContextToken: cameraContextToken,
                    attachPhoto: { data in await model.stageCameraPhoto(data, chat: chat, scope: cameraScope) }
                )
            }
        }
        .sheet(item: $annotationEdit) { attachment in
            ArtifactNoteEditor(model: model, chat: chat, attachment: attachment) { annotation in
                annotationEdit = nil
                Task { @MainActor in
                    await Task.yield()
                    workspaceRequest = WorkspaceBrowserRequest(initialFilePath: annotation.path,
                        preferredRootID: annotation.rootId, reanchor: annotation,
                        replacingAnnotationID: attachment.id)
                }
            }
        }
        .fullScreenCover(item: $messagePhotoGallery) { gallery in
            PhotoViewer(model: model, chat: chat, galleryFiles: gallery.files, initialFileID: gallery.initialFileID)
        }
        .fullScreenCover(item: $composerPhoto) { attachment in
            PhotoViewer(
                model: model,
                chat: chat,
                name: attachment.name,
                mimeType: attachment.mimeType,
                sourceID: attachment.id,
                localData: attachment.data,
                file: attachment.remoteFile
            )
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            guard importScope == model.assignmentScope, !model.accessEnded else { return }
            if case .success(let url) = result {
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                model.stage(url, chat: chat, mime: mime)
            } else if case .failure = result { model.controlErrors[chat.id] = "The file could not be opened. Try selecting it again." }
        }
        .safeAreaInset(edge: .bottom) {
            if !readOnly {
                composer
            }
        }
        .sheet(item: $selectedSubagent, onDismiss: {
            model.presentConversation(chat, root: rootChat)
            if restoreSubagentRoster {
                restoreSubagentRoster = false
                showingSubagents = true
            }
        }) { child in
            NavigationStack {
                ConversationView(model: model, chat: child.chatSummary(botId: chat.botId), rootChat: rootChat ?? chat, readOnly: true)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedSubagent = nil }
                                .accessibilityIdentifier("subagent-sheet-done")
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $selectedProjectSubagent, onDismiss: {
            model.presentConversation(chat, root: rootChat)
        }) { child in
            ProjectSubagentTranscriptView(model: model, parent: chat, child: child)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { surfaceVisible = true; model.presentConversation(chat, root: rootChat) }
        .onDisappear {
            surfaceVisible = false
            model.dismissConversation(chat)
            imagePasteTask?.cancel()
            model.dictation.captureControlsHidden(conversationID: chat.id)
            if model.searchFocus?.conversationID == chat.id { model.searchFocus = nil }
        }
        .onChange(of: conversationCovered) { _, covered in
            if covered { model.dictation.captureControlsHidden(conversationID: chat.id) }
        }
        .onChange(of: model.goals[chat.id] != nil) { _, exists in
            if !exists { showingGoal = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onChange(of: avatarMotionSignal, initial: true) { _, signal in
            var next = avatarMotion
            let status = ScienceAvatarObservedTurnStatus(
                rawValue: next.trackedActiveTurnID.flatMap { model.turn($0, in: chat.id)?.status }
            )
            next.reduce(
                activeTurnID: signal.activeTurnID,
                trackedTurnStatus: status,
                isPresented: signal.isPresented,
                reduceMotion: signal.reduceMotion,
                activeState: signal.state
            )
            if next != avatarMotion { avatarMotion = next }
        }
        .onChange(of: model.assignmentScope) { _, next in
            if cameraScope != nil, cameraScope != next { showingCamera = false; cameraScope = nil }
        }
        .onReceive(model.projects.$details) { details in
            let on = details[chat.id]?.planMode == true
            if planModeOn != on { planModeOn = on }
        }
        .onReceive(model.projects.$supportsModes) { supported in
            if supportsModes != supported { supportsModes = supported }
        }
        .task(id: chat.id) {
            async let history: Void = refreshNativeHistory()
            await model.open(chat, root: rootChat, readOnly: readOnly)
            await history
            if model.previewMode, ProcessInfo.processInfo.arguments.contains("-preview-document") { workspaceRequest = WorkspaceBrowserRequest() }
        }
        .task(id: chat.id + ":" + model.agentFamily(chat).rawValue) {
            guard !readOnly, (chat.botId != nil || model.isProject(chat)), model.agentFamily(chat) == .codex else { return }
            while !Task.isCancelled {
                await model.loadGoal(chat)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .modifier(ComposerUsageMonitor(model: model, chat: chat, readOnly: readOnly))
        .task(id: attachmentMetadataRequest) {
            let request = attachmentMetadataRequest
            guard !request.ids.isEmpty else { return }
            await model.loadFilesIfNeeded(chat, attachmentIDs: request.ids)
        }
    }
    @ViewBuilder private var conversationHeader: some View {
        if let botID = chat.botId {
            ConversationAvatarHeader(
                name: chat.title,
                identity: botID,
                hexColor: headerBot?.avatarColor,
                avatarShape: headerBot?.avatarShape,
                avatarPalette: headerBot?.avatarPalette,
                motion: avatarMotion.output,
                isLoaded: headerBot != nil
            )
        } else if let detail = model.projectDetail(chat) {
            ProjectConversationHeader(detail: detail)
        } else {
            Text(chat.title).font(.headline).lineLimit(1)
        }
    }
    private var conversationTitleAccessibilityLabel: String {
        if let botID = chat.botId {
            guard let bot = headerBot else { return "\(chat.title), conversation options" }
            let shape = ScienceAvatarPresentation.shape(rawValue: bot.avatarShape, identity: botID)
            let palette = ScienceAvatarPresentation.palette(rawValue: bot.avatarPalette, legacyColor: bot.avatarColor)
            return "\(chat.title), \(shape.title) character, \(palette.name) palette, conversation options"
        }
        if let detail = model.projectDetail(chat) {
            return "\(detail.title), \(detail.projectName) project, \(detail.family.title), conversation options"
        }
        return "\(chat.title), Group Chat options"
    }
    private var conversationTitleMenu: some View {
        Menu {
            Button("Conversation details", systemImage: "info.circle") { showingDetails = true }
            if chat.botId != nil || model.isProject(chat) {
                Button("Connected apps", systemImage: "square.grid.2x2") { showingApps = true }
                Button("\(model.agentFamily(chat).title) usage", systemImage: "chart.bar") { showingUsage = true }
            }
        } label: {
            HStack(spacing: 5) {
                conversationHeader
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(conversationTitleAccessibilityLabel)
        .accessibilityValue(chat.botId != nil ? avatarMotion.output.state.title : "")
        .accessibilityHint("Show conversation actions")
        .accessibilityIdentifier("conversation-title-menu")
    }
    private var composer: some View {
            let attachments = composerAttachments
            return VStack(alignment: .leading, spacing: 8) {
                DictationControls(controller: model.dictation, model: model, chat: chat)
                if let request = model.requests(for: chat).first(where: { !$0.isQuestion }) {
                    Button("Review request", systemImage: "hand.raised") {
                        requestedScrollID = "approval-" + request.id
                        workspaceRequest = nil
                    }.font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("review-approval-request")
                }
                QuestionDock(model: model, chat: chat)
                if (!chat.isArchived || model.isSubagent(chat)) && (chat.botId != nil || model.groups[chat.id] != nil || model.isProject(chat)) {
                    if model.nativeHistoryFailures.contains(chat.id) {
                        Button("Couldn’t check for new turns. Try again") { Task { await model.reloadNativeHistory(chat) } }
                            .font(.caption).frame(minHeight: 44)
                            .accessibilityIdentifier("native-history-retry")
                    }
                    if let error = model.controlErrors[chat.id] { FailureDetails(message: error) }
                    if let error = model.composerErrors[chat.id] {
                        FailureDetails("Message not saved", message: error)
                    }
                    if model.isProject(chat), (model.projectSubagents[chat.id] ?? []).isEmpty,
                       let detail = model.projectSubagentErrors[chat.id] {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.botWorking(chat.id), let issue = model.snapshots[chat.id]?.latestRequestIssue {
                        Text(issue)
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("last-request-issue")
                    }
                    if model.loadingPhotos.contains(chat.id) { ProgressView("Loading photo…") }
                    else if model.uploading.contains(chat.id) { ProgressView("Uploading attachments…") }
                    else if model.preparingSends.contains(chat.id) { ProgressView("Preparing message…") }
                    VStack(spacing: 4) {
                        HStack(alignment: .bottom, spacing: 4) {
                            ComputerDock(isPresented: $showingComputer)
                            FilesDock(isPresented: workspaceRequest != nil) {
                                if workspaceRequest == nil { workspaceRequest = WorkspaceBrowserRequest() }
                                else { workspaceRequest = nil }
                            }
                            Spacer(minLength: 0)
                            if let goal = model.goals[chat.id], (chat.botId != nil || model.isProject(chat)),
                               model.groups[chat.id] == nil, !model.isSubagent(chat) {
                                GoalDock(goal: goal, error: model.goalErrors[chat.id], isPresented: $showingGoal,
                                    save: { objective, budget, timeBudget in
                                        await model.updateGoal(chat, objective: objective,
                                                               tokenBudget: budget, timeBudgetSeconds: timeBudget)
                                    },
                                    pause: { await model.pauseGoal(chat) },
                                    resume: { await model.resumeGoal(chat) },
                                    clear: { await model.clearGoal(chat) })
                            }
                            if !(model.subagents[chat.id] ?? []).isEmpty {
                                SubagentDock(agents: model.subagents[chat.id] ?? [], available: model.subagentAvailability[chat.id] != false,
                                    avatarShape: ScienceAvatarPresentation.shape(rawValue: headerBot?.avatarShape, identity: chat.botId ?? chat.id),
                                    avatarPalette: ScienceAvatarPresentation.palette(rawValue: headerBot?.avatarPalette, legacyColor: headerBot?.avatarColor),
                                    isPresented: $showingSubagents) { child in
                                    restoreSubagentRoster = true
                                    showingSubagents = false
                                    Task { @MainActor in
                                        await Task.yield()
                                        selectedSubagent = child
                                    }
                                }
                            }
                            if model.isProject(chat), !(model.projectSubagents[chat.id] ?? []).isEmpty {
                                ProjectSubagentDock(agents: model.projectSubagents[chat.id] ?? [],
                                    detail: model.projectSubagentErrors[chat.id], isPresented: $showingProjectSubagents) { child in
                                    showingProjectSubagents = false
                                    Task { @MainActor in
                                        await Task.yield()
                                        selectedProjectSubagent = child
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    DictationComposerSurface(controller: model.dictation, conversationID: chat.id) {
                    VStack(spacing: 0) {
                    if !attachments.isEmpty {
                        ComposerAttachmentStrip(
                            attachments: attachments,
                            imagePreviews: model.imagePreviews,
                            imagePreviewScope: model.imagePreviewScope,
                            chatID: chat.id,
                            staleAnnotationIDs: Set(attachments.filter { model.isAnnotationStale($0.id, chat: chat.id) }.map(\.id)),
                            removalDisabled: model.preparingSends.contains(chat.id) || model.uploading.contains(chat.id) || model.sending.contains(chat.id) || model.composers[chat.id]?.pending != nil,
                            loadRemoteData: { [model, chat] file in try await model.download(file, chat: chat) },
                            openPhoto: { composerPhoto = $0 },
                            remove: { model.removeStaged($0, chat: chat.id) },
                            editAnnotation: { annotationEdit = $0 }
                        )
                    }
                    if let message = model.usageLimitMessage(chat) {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.top, 8)
                            .accessibilityIdentifier("composer-usage-limit")
                    }
                    if model.isProject(chat), supportsModes, planModeOn {
                        HStack(spacing: 0) {
                            PlanModeChip(isDisabled: model.savingComposerSettings.contains(chat.id) || model.accessEnded) {
                                Task { await setPlanMode(false, model: model, library: model.projects, chat: chat) }
                            }
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 8).padding(.top, 4)
                    }
                    messageEditor.padding(.horizontal, 8)
                    HStack(alignment: .center, spacing: 4) {
                        Group {
                            Menu {
                                // The menu opens upward and lists bottom-up, so Plan mode
                                // appears below the attachment actions.
                                if model.isProject(chat), supportsModes {
                                    Toggle(isOn: Binding(get: { planModeOn }, set: { value in
                                        Task { await setPlanMode(value, model: model, library: model.projects, chat: chat) }
                                    })) { Label("Plan mode", systemImage: "list.bullet.clipboard") }
                                        .disabled(model.savingComposerSettings.contains(chat.id) || model.accessEnded || model.previewMode)
                                        .accessibilityIdentifier("composer-plan-mode")
                                }
                                Button("Camera", systemImage: "camera") {
                                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                                    cameraScope = model.assignmentScope; showingCamera = true
                                }.disabled(!model.canAttach(chat) || model.loadingPhotos.contains(chat.id))
                                Button("Add photo", systemImage: "photo") {
                                    importScope = model.assignmentScope; selectingPhoto = true
                                }.disabled(!model.canAttach(chat) || model.loadingPhotos.contains(chat.id))
                                Button(model.attachmentsSupported(chat) ? "Attach file" : "Attachments unavailable — update Wonder on your Mac", systemImage: "paperclip") {
                                    importScope = model.assignmentScope; importing = true
                                }.disabled(!model.canAttach(chat) || model.loadingPhotos.contains(chat.id))
                                if model.activeTurn(chat.id) != nil {
                                    Button("Stop response", systemImage: "stop.fill") { Task { await model.stop(chat) } }
                                        .disabled(model.stopping.contains(chat.id) || model.accessEnded || model.previewMode)
                                }
                            } label: { Image(systemName: "plus").font(.system(size: 22)).frame(width: 44, height: 44) }
                                .accessibilityLabel("Message actions")
                        }
                        DictationButton(controller: model.dictation, chat: chat,
                            unavailable: model.previewMode || model.accessEnded || model.preparingSends.contains(chat.id) || model.uploading.contains(chat.id))
                        if model.isSubagent(chat) {
                            Text(model.subagentSummary(for: chat.id)?.canAcceptDirectInput == false ? "Direct input unavailable" : "Inherited settings")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("subagent-settings-state")
                        } else if let botID = chat.botId {
                            ComposerSettings(model: model, chat: chat, botID: botID)
                        } else if model.isProject(chat) {
                            ProjectComposerSettings(model: model, library: model.projects, chat: chat)
                        } else { Spacer(minLength: 0) }
                        if model.activeTurn(chat.id) != nil {
                            Button { Task { await model.stop(chat) } } label: {
                                if model.stopping.contains(chat.id) { ProgressView().frame(width: 44, height: 44) }
                                else { Image(systemName: "stop.fill").font(.system(size: 20)).frame(width: 44, height: 44) }
                            }.accessibilityLabel("Stop response")
                                .disabled(model.stopping.contains(chat.id) || model.accessEnded || model.previewMode)
                        }
                        if chat.botId == nil || model.agentFamily(chat) == .claude {
                            Button { Task { await model.send(chat) } } label: {
                                Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                            }
                            .foregroundStyle(Color(uiColor: .systemBackground))
                            .background(model.canSend(chat) ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
                            .accessibilityLabel("Send message").accessibilityIdentifier("send-message")
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!model.canSend(chat))
                        } else {
                        Menu {
                            Button("Guide", systemImage: "arrow.turn.up.right") { Task { await model.guide(chat) } }
                                .disabled(!model.canGuide(chat))
                            Button("Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { Task { await model.send(chat) } }
                                .disabled(!model.canSend(chat))
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 44)
                        } primaryAction: {
                            Task { await model.send(chat) }
                        }
                        .menuOrder(.fixed)
                        .menuStyle(.borderlessButton)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                        .background(model.canSend(chat) ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
                        .accessibilityLabel(model.botWorking(chat.id) && chat.botId != nil ? "Queue message" : "Send message").accessibilityIdentifier("send-message")
                        .accessibilityHint("Touch and hold for message actions.")
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canSend(chat) && !model.previewMode)
                        }
                    }
                    }
                    }.padding(5)
                        .foregroundStyle(.primary)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
                    }
                    if (model.composers[chat.id]?.draft.utf8.count ?? 0) > 65536 {
                        Text("Message too long").font(.caption).foregroundStyle(.secondary)

                    }
                }
                if chat.isArchived {
                    Text(model.isSubagent(chat)
                         ? "Archived subagent — sending reopens this exact conversation."
                         : "Archived conversation")
                        .font(.caption).foregroundStyle(.secondary)
                }

                    }.frame(maxWidth: 768).padding(.horizontal).padding(.top, 4).padding(.bottom, 2)
                .frame(maxWidth: .infinity)
    }
    private var composerAttachments: [ComposerAttachment] {
        let intent = model.composers[chat.id]
        var result: [ComposerAttachment] = []
        var seen = Set<String>()

        for file in intent?.stagedFiles ?? [] where seen.insert(file.id).inserted {
            let metadata = file.uploaded
            result.append(ComposerAttachment(
                id: file.id,
                name: file.name,
                mimeType: file.mimeType,
                data: file.data,
                remoteFile: metadata,
                sha256: metadata?.sha256,
                byteSize: metadata?.byteSize ?? file.data.count,
                state: metadata?.state ?? "local",
                updatedAt: metadata?.updatedAt ?? "composer"
            ))
        }

        var metadataByID: [String: ConversationFile] = [:]
        for file in model.files[chat.id] ?? [] { metadataByID[file.id] = file }
        for id in intent?.draftAttachmentIds ?? [] where seen.insert(id).inserted {
            if let file = metadataByID[id] {
                result.append(ComposerAttachment(
                    id: id,
                    name: file.name,
                    mimeType: file.mimeType ?? "application/octet-stream",
                    data: nil,
                    remoteFile: file,
                    sha256: file.sha256,
                    byteSize: file.byteSize,
                    state: file.state,
                    updatedAt: file.updatedAt
                ))
            } else {
                result.append(ComposerAttachment(
                    id: id,
                    name: ComposerAttachment.fallbackName,
                    mimeType: "application/octet-stream",
                    data: nil,
                    remoteFile: nil,
                    sha256: nil,
                    byteSize: nil,
                    state: "missing",
                    updatedAt: "composer"
                ))
            }
        }
        return result
    }
    private var messageEditor: some View {
        BoundedComposerEditor(text: Binding(
            get: { model.composers[chat.id]?.draft ?? "" },
            set: { model.editDraft($0, chat: chat.id) }),
            maximumLines: typeSize >= .accessibility3 ? 1 : typeSize.isAccessibilitySize ? 2 : 6,
            label: "Message \(chat.title)", editable: !model.preparingSends.contains(chat.id) && !model.uploading.contains(chat.id),
            canPasteImages: model.canAttach(chat) && !model.loadingPhotos.contains(chat.id),
            pasteImages: { providers in
                let scope = model.assignmentScope
                imagePasteTask?.cancel()
                imagePasteTask = Task { await model.stagePastedImages(providers, chat: chat, scope: scope) }
            })
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                if (model.composers[chat.id]?.draft ?? "").isEmpty {
                    Text("Message \(chat.title)").foregroundStyle(.secondary)
                        .padding(.top, 12).padding(.leading, 5)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel("Message \(chat.title)")
            .accessibilityIdentifier("message-draft")
    }
}

struct ComposerAttachment: Identifiable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let data: Data?
    let remoteFile: ConversationFile?
    let sha256: String?
    let byteSize: Int?
    let state: String
    let updatedAt: String

    var showsImage: Bool { mimeType.hasPrefix("image/") }
    var isAnnotation: Bool { mimeType == ArtifactAnnotation.mimeType }
    var iconName: String {
        if mimeType.hasPrefix("image/") { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType.hasPrefix("text/") { return "doc.text" }
        return "paperclip"
    }

    static let fallbackName = "Saved attachment"
}

struct ComposerAttachmentStrip: View {
    let attachments: [ComposerAttachment]
    let imagePreviews: ToolImagePreviews
    let imagePreviewScope: UUID
    let chatID: String
    var staleAnnotationIDs: Set<String> = []
    let removalDisabled: Bool
    let loadRemoteData: @Sendable (ConversationFile) async throws -> Data
    let openPhoto: (ComposerAttachment) -> Void
    let remove: (String) -> Void
    var editAnnotation: ((ComposerAttachment) -> Void)? = nil

    private var containsImage: Bool { attachments.contains { $0.showsImage } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 8) {
                ForEach(attachments) { attachment in
                    ComposerAttachmentItem(
                        attachment: attachment,
                        imagePreviews: imagePreviews,
                        imagePreviewScope: imagePreviewScope,
                        chatID: chatID,
                        isStale: staleAnnotationIDs.contains(attachment.id),
                        removalDisabled: removalDisabled,
                        loadRemoteData: loadRemoteData,
                        openPhoto: openPhoto,
                        remove: remove,
                        editAnnotation: editAnnotation
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .frame(height: containsImage ? 88 : 52)
        .accessibilityIdentifier("composer-attachments")
    }
}

private struct ComposerAttachmentItem: View {
    let attachment: ComposerAttachment
    let imagePreviews: ToolImagePreviews
    let imagePreviewScope: UUID
    let chatID: String
    let isStale: Bool
    let removalDisabled: Bool
    let loadRemoteData: @Sendable (ConversationFile) async throws -> Data
    let openPhoto: (ComposerAttachment) -> Void
    let remove: (String) -> Void
    let editAnnotation: ((ComposerAttachment) -> Void)?
    @State private var thumbnail: UIImage?
    @State private var failed = false

    private var thumbnailRequest: ToolImageRequest? {
        guard attachment.showsImage else { return nil }
        return ToolImageRequest(
            scope: imagePreviewScope,
            chatID: chatID,
            fileID: attachment.id,
            sha256: attachment.sha256,
            mimeType: attachment.mimeType,
            byteSize: attachment.byteSize,
            state: attachment.state,
            updatedAt: attachment.updatedAt
        )
    }
    private var removalLabel: String {
        "Remove \(attachment.isAnnotation ? "preview note" : attachment.showsImage ? "photo" : "file") \(attachment.name)"
    }

    var body: some View {
        Group {
            if attachment.showsImage {
                imageTile
            } else {
                fileChip
            }
        }
        .accessibilityIdentifier("composer-attachment:\(attachment.id)")
        .accessibilityValue(attachment.showsImage ? (thumbnail != nil ? "Loaded" : failed ? "Unavailable" : "Loading") : "")
        .task(id: thumbnailRequest) { await loadThumbnail(thumbnailRequest) }
        .onDisappear { thumbnail = nil }
    }

    private var imageTile: some View {
        ZStack(alignment: .topTrailing) {
            Button { openPhoto(attachment) } label: {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .accessibilityHidden(true)
                    } else if failed {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView()
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 72, height: 72)
                .clipped()
            }
            .buttonStyle(.plain)
            .frame(width: 72, height: 72)
            .contentShape(Rectangle())
            .accessibilityLabel("Open photo \(attachment.name)")
            .accessibilityIdentifier("composer-attachment-open:\(attachment.id)")
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            removeButton
                .offset(x: 8, y: -8)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
        .frame(width: 88, height: 88, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo \(attachment.name)")
        .accessibilityValue(thumbnail != nil ? "Loaded" : failed ? "Unavailable" : "Loading")
    }

    private var fileChip: some View {
        ZStack(alignment: .topTrailing) {
            let label = HStack(spacing: 6) {
                Image(systemName: attachment.iconName)
                    .foregroundStyle(.secondary)
                if isStale { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                Text(attachment.isAnnotation ? "\(isStale ? "Source changed · " : "Preview note · ")\(attachment.name.replacingOccurrences(of: ".annotation.json", with: ""))" : attachment.name)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .padding(.leading, 10)
            .padding(.trailing, 24)
            .frame(minHeight: 44)
            .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
            if attachment.isAnnotation, let editAnnotation {
                Button { editAnnotation(attachment) } label: { label }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(isStale ? "Source changed. Re-anchor preview note" : "Edit preview note") for \(attachment.name)")
                    .accessibilityIdentifier("composer-annotation-edit")
            } else { label }
            removeButton
                .offset(x: 8, y: -8)
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
        .frame(minHeight: 52, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
    }

    private var removeButton: some View {
        Button { remove(attachment.id) } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .background(.ultraThinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(removalDisabled)
        .accessibilityLabel(removalLabel)
        .accessibilityIdentifier("composer-attachment-remove:\(attachment.id)")
    }

    private func loadThumbnail(_ request: ToolImageRequest?) async {
        thumbnail = nil
        failed = false
        guard let request else { return }
        let localData = attachment.data
        let remoteFile = attachment.remoteFile
        let remoteLoader = loadRemoteData
        do {
            let image = try await imagePreviews.image(for: request) {
                if let localData { return localData }
                guard let remoteFile else { throw FileFailure.unsupported }
                return try await remoteLoader(remoteFile)
            }
            try Task.checkCancellation()
            guard request == thumbnailRequest else { return }
            thumbnail = image
        } catch {
            guard !Task.isCancelled, request == thumbnailRequest else { return }
            failed = true
        }
    }
}

/// Explicitly bounded UIKit sizing avoids the vertical SwiftUI TextField's
/// intrinsic-size feedback when a full dictation result replaces a short draft.
struct BoundedComposerEditor: UIViewRepresentable {
    @Binding var text: String
    let maximumLines: Int
    let label: String
    let editable: Bool
    var canPasteImages = false
    var pasteImages: (([NSItemProvider]) -> Void)?

    func makeUIView(context: Context) -> ComposerTextView {
        // TextKit 1 avoids the TextKit 2 re-layout path seen in the hang sample.
        let view = ComposerTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .label
        view.accessibilityIdentifier = "message-draft"
        view.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        view.isScrollEnabled = true
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: ComposerTextView, context: Context) {
        context.coordinator.parent = self
        view.canPasteImages = canPasteImages
        view.pasteImages = pasteImages
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        if view.isEditable != editable { view.isEditable = editable }
        if view.accessibilityLabel != label { view.accessibilityLabel = label }
        if view.markedTextRange != nil {
            context.coordinator.beginComposition()
            return
        }
        // A disabled model may have rejected an IME commit during upload. Retry
        // after this SwiftUI update, using the latest draft rather than stale text.
        if context.coordinator.pendingCommit != nil || context.coordinator.compositionBase != nil {
            context.coordinator.scheduleCommit(view)
            return
        }
        context.coordinator.replaceText(text, in: view)
        context.coordinator.lastSynchronizedText = text
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, width.isFinite else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let maximum = max(44, lineHeight * CGFloat(maximumLines) + insets)
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: min(maximum, max(44, ceil(measured.height))))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BoundedComposerEditor
        var lastSynchronizedText: String
        var compositionBase: String?
        var pendingCommit: ComposerComposition.PendingCommit?
        private var isCommitting = false
        private var commitScheduled = false
        init(_ parent: BoundedComposerEditor) { self.parent = parent; lastSynchronizedText = parent.text }
        func beginComposition() { if compositionBase == nil { compositionBase = lastSynchronizedText } }
        func textViewDidChange(_ textView: UITextView) { commit(textView) }
        func textViewDidChangeSelection(_ textView: UITextView) {
            if compositionBase != nil, textView.markedTextRange == nil { commit(textView) }
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            textView.unmarkText()
            commit(textView)
        }
        func scheduleCommit(_ textView: UITextView) {
            guard parent.editable, !commitScheduled else { return }
            commitScheduled = true
            DispatchQueue.main.async { [weak self, weak textView] in
                guard let self else { return }
                self.commitScheduled = false
                guard let textView, self.parent.editable else { return }
                self.commit(textView)
            }
        }
        private func commit(_ textView: UITextView) {
            guard !isCommitting else { return }
            guard textView.markedTextRange == nil else { beginComposition(); return }
            let committed = textView.text ?? ""
            let pending = pendingCommit?.replacingCommittedText(committed) ?? ComposerComposition.PendingCommit(
                base: compositionBase ?? lastSynchronizedText, committed: committed)
            pendingCommit = pending
            guard parent.editable else { return }
            isCommitting = true
            defer { isCommitting = false }
            guard let merged = pending.apply(to: parent.text, save: { text in
                if self.parent.text != text { self.parent.text = text }
                return self.parent.text
            }) else { return }
            // Clear only after the binding acknowledges the text. Programmatic
            // text/selection delegate callbacks cannot recursively merge it again.
            pendingCommit = nil; compositionBase = nil; lastSynchronizedText = merged
            replaceText(merged, in: textView)
        }
        func replaceText(_ text: String, in view: UITextView) {
            guard view.text != text else { return }
            let wasCommitting = isCommitting
            isCommitting = true
            defer { isCommitting = wasCommitting }
            let selection = view.selectedRange
            view.text = text
            let count = (text as NSString).length
            let location = min(selection.location, count)
            view.selectedRange = NSRange(location: location, length: min(selection.length, count - location))
        }
    }
}

/// Keep Paste in the system edit menu, including for an image-only clipboard.
/// Inspect type metadata while building the menu; read contents only on Paste.
/// The keyboard's paste suggestion (iOS 27) and drops paste item providers
/// instead of calling paste(_:), so images are routed from that path too.
final class ComposerTextView: UITextView, UITextPasteDelegate {
    // UIKit's usingTextLayoutManager factory bypasses Swift property
    // initializers, so stored state here must be valid when zero-filled.
    var canPasteImages = false { didSet { if canPasteImages != oldValue { updatePasteConfiguration() } } }
    var pasteImages: (([NSItemProvider]) -> Void)? { didSet { if (pasteImages == nil) != (oldValue == nil) { updatePasteConfiguration() } } }
    private var capturedTextPasteConfiguration = false
    private var textPasteConfiguration: UIPasteConfiguration?
    private var pendingImageProviders: [NSItemProvider]?
    private var acceptsImagePaste: Bool { isEditable && canPasteImages && pasteImages != nil }
    private static let imageTypes = [UTType.image, .png, .jpeg, .heic, .tiff, .gif].map(\.identifier)

    private static func isImage(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    private func updatePasteConfiguration() {
        if !capturedTextPasteConfiguration {
            capturedTextPasteConfiguration = true
            textPasteConfiguration = pasteConfiguration
        }
        let base = textPasteConfiguration?.acceptableTypeIdentifiers ?? []
        pasteConfiguration = acceptsImagePaste
            ? UIPasteConfiguration(acceptableTypeIdentifiers: base + Self.imageTypes.filter { !base.contains($0) })
            : textPasteConfiguration
        if pasteDelegate == nil { pasteDelegate = self }
    }

    /// Item-provider pastes run through UIKit's text paste pipeline. Accepting
    /// image types above lets them reach it; each image then becomes a staged
    /// attachment rather than being dropped by this plain-text editor.
    func textPasteConfigurationSupporting(_ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
                                          transform item: any UITextPasteItem) {
        guard acceptsImagePaste, Self.isImage(item.itemProvider) else { item.setDefaultResult(); return }
        item.setNoResult()
        // Items in one paste are transformed together; stage them as one batch.
        if pendingImageProviders == nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, let providers = self.pendingImageProviders else { return }
                self.pendingImageProviders = nil
                if self.acceptsImagePaste { self.pasteImages?(providers) }
            }
        }
        pendingImageProviders = (pendingImageProviders ?? []) + [item.itemProvider]
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return isEditable && canPasteImages && pasteImages != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if UIPasteboard.general.hasImages {
            guard isEditable, canPasteImages, let pasteImages else { return }
            pasteImages(UIPasteboard.general.itemProviders.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            })
            return
        }
        super.paste(sender)
    }
}

struct MessageAttachmentPresentation: Identifiable, Sendable {
    let id: String
    let file: ConversationFile?
    let name: String
    let mimeType: String?

    init(id: String, file: ConversationFile?) {
        self.id = id
        self.file = file
        self.name = file?.name ?? "Attachment unavailable"
        self.mimeType = file?.mimeType
    }

    var isImage: Bool { PhotoViewerRouting.isImage(mimeType: mimeType) }
    var iconName: String {
        if isImage { return "photo" }
        if mimeType == "application/pdf" { return "doc.richtext" }
        if mimeType?.hasPrefix("text/") == true { return "doc.text" }
        return "paperclip"
    }
}

enum ConversationAttachmentGallery {
    nonisolated static func imageFiles(_ files: [ConversationFile], attachmentIDs: [String]? = nil) -> [ConversationFile] {
        let filtered = files.filter(PhotoViewerRouting.isImage)
        guard let attachmentIDs else { return filtered }
        let byID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        return attachmentIDs.compactMap { byID[$0] }
    }
}

struct MessagePhotoGallery: Identifiable {
    let files: [ConversationFile]
    let initialFileID: String
    var id: String { initialFileID + ":" + files.map(\.id).joined(separator: ",") }
}

private struct MessageAttachmentStrip: View {
    let attachments: [MessageAttachmentPresentation]
    let imagePreviews: ToolImagePreviews
    let imagePreviewScope: UUID
    let chatID: String
    let loadRemoteData: @Sendable (ConversationFile) async throws -> Data
    let openImage: (MessageAttachmentPresentation) -> Void
    let openDocument: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    MessageAttachmentItem(
                        attachment: attachment,
                        imagePosition: attachment.isImage ? imagePosition(for: attachment) : nil,
                        imageCount: imageCount,
                        imagePreviews: imagePreviews,
                        imagePreviewScope: imagePreviewScope,
                        chatID: chatID,
                        loadRemoteData: loadRemoteData,
                        openImage: openImage,
                        openDocument: openDocument
                    )
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .frame(height: attachments.contains(where: \.isImage) ? 82 : 44)
        .accessibilityIdentifier("message-attachments")
    }

    private var imageCount: Int { attachments.filter(\.isImage).count }
    private func imagePosition(for attachment: MessageAttachmentPresentation) -> Int? {
        guard attachment.isImage else { return nil }
        return attachments.prefix { $0.id != attachment.id }.filter(\.isImage).count + 1
    }
}

private struct MessageAttachmentItem: View {
    let attachment: MessageAttachmentPresentation
    let imagePosition: Int?
    let imageCount: Int
    let imagePreviews: ToolImagePreviews
    let imagePreviewScope: UUID
    let chatID: String
    let loadRemoteData: @Sendable (ConversationFile) async throws -> Data
    let openImage: (MessageAttachmentPresentation) -> Void
    let openDocument: () -> Void
    @State private var thumbnail: UIImage?
    @State private var failed = false

    private var request: ToolImageRequest? {
        guard let file = attachment.file, attachment.isImage else { return nil }
        return ToolImageRequest(scope: imagePreviewScope, chatID: chatID, file: file)
    }

    var body: some View {
        Group {
            if attachment.isImage {
                Button { openImage(attachment) } label: {
                    ZStack {
                        Color(uiColor: .secondarySystemBackground)
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 72, height: 72)
                                .accessibilityHidden(true)
                        } else if failed || attachment.file == nil {
                            Image(systemName: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        } else {
                            ProgressView().accessibilityHidden(true)
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(imageLabel)
                .accessibilityIdentifier("message-attachment-open:\(attachment.id)")
                .accessibilityValue(thumbnail != nil ? "Loaded" : failed || attachment.file == nil ? "Unavailable" : "Loading")
            } else {
                Button(action: openDocument) {
                    Label(attachment.name, systemImage: attachment.iconName)
                        .font(.subheadline)
                        .lineLimit(1)
                        .frame(minHeight: 40)
                        .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .background(Color(uiColor: .tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .accessibilityLabel(attachment.name)
                .accessibilityIdentifier("message-attachment-file:\(attachment.id)")
            }
        }
        .task(id: request) { await loadThumbnail(request) }
        .onDisappear { thumbnail = nil }
    }

    private var imageLabel: String {
        if let imagePosition, imageCount > 1 {
            return "Open image \(attachment.name), \(imagePosition) of \(imageCount)"
        }
        return "Open image \(attachment.name)"
    }

    private func loadThumbnail(_ request: ToolImageRequest?) async {
        thumbnail = nil
        failed = false
        guard let request, let file = attachment.file else {
            if attachment.isImage { failed = true }
            return
        }
        do {
            let image = try await imagePreviews.image(for: request) { [loadRemoteData] in
                try await loadRemoteData(file)
            }
            try Task.checkCancellation()
            guard request == self.request else { return }
            thumbnail = image
        } catch {
            guard !Task.isCancelled, request == self.request else { return }
            failed = true
        }
    }
}

struct MessageRow: View {
    let row: ReadRow
    var isGroup = false
    var showIdentity = false
    var pending: PendingSend? = nil
    var recoveredBeforeReconnect = false
    var isSending = false
    var canRetry = false
    var retry: () -> Void = {}
    var attachments: [MessageAttachmentPresentation] = []
    var imagePreviews: ToolImagePreviews? = nil
    var imagePreviewScope = UUID()
    var chatID = "message"
    var loadRemoteData: (@Sendable (ConversationFile) async throws -> Data)? = nil
    var openImage: (MessageAttachmentPresentation) -> Void = { _ in }
    var openDocument: () -> Void = {}
    var avatarColor: String? = nil
    var avatarShape: String? = nil
    var avatarPalette: String? = nil
    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            if row.isUser { Spacer(minLength: 32) }
            HStack(alignment: .top, spacing: 8) {
                if !row.isUser && isGroup {
                    if showIdentity {
                        ChatAvatar(name: row.author, identity: row.authorId, hexColor: avatarColor, avatarShape: avatarShape, avatarPalette: avatarPalette)
                    } else {
                        Color.clear.frame(width: 34, height: 0).accessibilityHidden(true)
                    }
                }
                bubble
            }.frame(maxWidth: 640, alignment: row.isUser ? .trailing : .leading)
            if let pending {
                if isSending {
                    ProgressView().frame(width: 44, height: 44)
                        .accessibilityLabel("Sending message")
                } else if pending.receipt == nil {
                    Button(action: retry) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.body.weight(.semibold)).foregroundStyle(.red)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRetry)
                    .accessibilityLabel(pending.rejected == true ? "Restore unsent Guide to draft" : "Delivery unconfirmed. Try again")
                    .accessibilityHint(canRetry ? "Retries this same message without creating a duplicate." : "Reconnect to your Mac to try again.")
                    .accessibilityIdentifier("retry-message")
                } else {
                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .accessibilityLabel("Received by your Mac")
                }
            }
            if !row.isUser { Spacer(minLength: 32) }
        }.frame(maxWidth: .infinity, alignment: row.isUser ? .trailing : .leading)
            .accessibilityElement(children: .contain)
    }
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            if recoveredBeforeReconnect {
                Text("Delivery unconfirmed before reconnect")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("recovered-message-status")
                Button("Copy message", systemImage: "doc.on.doc") { UIPasteboard.general.string = row.text }
                    .font(.caption)
                    .accessibilityIdentifier("copy-recovered-message")
            }
            Group {
                if row.isUser {
                    VStack(alignment: .leading, spacing: 4) {
                        if !attachments.isEmpty, let imagePreviews, let loadRemoteData {
                            MessageAttachmentStrip(
                                attachments: attachments,
                                imagePreviews: imagePreviews,
                                imagePreviewScope: imagePreviewScope,
                                chatID: chatID,
                                loadRemoteData: loadRemoteData,
                                openImage: openImage,
                                openDocument: openDocument
                            )
                        }
                        if !row.text.isEmpty { Text(row.text).textSelection(.enabled) }
                    }
                }
                else { BotMessageText(text: row.text) }
            }.font(row.isCommentary ? .subheadline : .body)
                .modifier(ChatBubbleSurface(isUser: row.isUser))
        }
            .accessibilityElement(children: row.attachmentIds.isEmpty && !recoveredBeforeReconnect ? .combine : .contain)
            .accessibilityLabel(row.isUser ? row.text : "\(row.author): \(row.text)")
    }
}

enum ChatBubblePalette: String, CaseIterable {
    case standard, ocean, violet
    static let storageKey = "chatBubblePalette"
    var title: String {
        switch self {
        case .standard: "Standard"
        case .ocean: "Ocean"
        case .violet: "Violet"
        }
    }
    func fill(isUser: Bool) -> Color {
        switch self {
        case .standard:
            Color(uiColor: isUser ? .systemGray4 : .secondarySystemBackground)
        case .ocean:
            isUser ? Self.oceanUser : Self.oceanAgent
        case .violet:
            isUser ? Self.violetUser : Self.violetAgent
        }
    }
    private static let oceanUser = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.10, green: 0.25, blue: 0.36, alpha: 1)
            : UIColor(red: 0.84, green: 0.92, blue: 0.97, alpha: 1)
    })
    private static let oceanAgent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.15, green: 0.20, blue: 0.24, alpha: 1)
            : UIColor(red: 0.94, green: 0.97, blue: 0.99, alpha: 1)
    })
    private static let violetUser = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.29, green: 0.19, blue: 0.35, alpha: 1)
            : UIColor(red: 0.93, green: 0.86, blue: 0.97, alpha: 1)
    })
    private static let violetAgent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.22, green: 0.18, blue: 0.25, alpha: 1)
            : UIColor(red: 0.97, green: 0.95, blue: 0.98, alpha: 1)
    })
}

private struct ChatBubblePaletteKey: EnvironmentKey {
    static let defaultValue: ChatBubblePalette = .standard
}

extension EnvironmentValues {
    var chatBubblePalette: ChatBubblePalette {
        get { self[ChatBubblePaletteKey.self] }
        set { self[ChatBubblePaletteKey.self] = newValue }
    }
}

struct ChatBubbleSurface: ViewModifier {
    var isUser = false
    @Environment(\.chatBubblePalette) private var palette
    func body(content: Content) -> some View {
        content.padding(.horizontal, 14).padding(.vertical, 10)
            .foregroundStyle(.primary)
            .background(palette.fill(isUser: isUser), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A plan the agent proposed, shown as the answer to review rather than as
/// work. The newest finished plan in a plan-mode thread can be implemented.
struct PlanCard: View {
    let text: String?
    let isRunning: Bool
    let canImplement: Bool
    let isImplementing: Bool
    let implement: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Plan", systemImage: "list.bullet.clipboard")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            if let text { BotMessageText(text: text) }
            else if isRunning { ProgressView().accessibilityLabel("Writing the plan") }
            if canImplement || isImplementing {
                Button(action: implement) {
                    HStack(spacing: 8) {
                        if isImplementing { ProgressView() }
                        Text("Implement plan")
                    }.frame(maxWidth: .infinity).frame(minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isImplementing)
                .accessibilityIdentifier("implement-plan")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("plan-card")
    }
}

struct BotMessageText: View {
    let text: String
    fileprivate struct Block { let text: String; let code: Bool; var inline: AttributedString? = nil }
    /// Parsed once per distinct message text. Rows re-enter the lazy stack on
    /// every scroll; settled replies keep their text, so they hit the cache.
    @MainActor private final class Parsed {
        let blocks: [Block]
        init(_ blocks: [Block]) { self.blocks = blocks }
        static let cache: NSCache<NSString, Parsed> = {
            let cache = NSCache<NSString, Parsed>()
            cache.countLimit = 300
            cache.totalCostLimit = 2_000_000
            return cache
        }()
    }
    private var parsedBlocks: [Block] {
        let key = text as NSString
        if let hit = Parsed.cache.object(forKey: key) { return hit.blocks }
        let parsed = blocks.map { block in
            block.code ? block : Block(text: block.text, code: false, inline: inline(block.text))
        }
        Parsed.cache.setObject(Parsed(parsed), forKey: key, cost: key.length)
        return parsed
    }
    private var blocks: [Block] {
        var result: [Block] = []
        var lines: [String] = []
        var fence: (Character, Int)?
        func flush(code: Bool) {
            if !lines.isEmpty { result.append(Block(text: lines.joined(separator: "\n"), code: code)); lines = [] }
        }
        for line in text.components(separatedBy: "\n") {
            let indent = line.prefix(while: { $0 == " " }).count
            let candidate = line.dropFirst(indent)
            let marker = candidate.first
            let count = candidate.prefix(while: { $0 == marker }).count
            if indent <= 3, let marker, (marker == "`" || marker == "~"), count >= 3 {
                if let current = fence {
                    if marker == current.0, count >= current.1,
                       candidate.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                        flush(code: true); fence = nil; continue
                    }
                } else {
                    if marker != "`" || !candidate.dropFirst(count).contains("`") {
                        flush(code: false); fence = (marker, count); continue
                    }
                }
            }
            lines.append(line)
        }
        flush(code: fence != nil)
        return result
    }
    private func inline(_ source: String) -> AttributedString {
        var value = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        // Model text cannot turn a chat link into a local-file or app-control link.
        for run in Array(value.runs) {
            if let url = run.link, !["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                value[run.range].link = nil
            }
        }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsedBlocks.enumerated()), id: \.offset) { _, block in
                if block.code {
                    ScrollView(.horizontal) {
                        Text(block.text).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                            .padding(10)
                    }.background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(block.inline ?? AttributedString(block.text)).textSelection(.enabled)
                }
            }
        }
    }
}

struct ChatAvatar: View {
    let name: String
    var identity: String? = nil
    var hexColor: String? = nil
    var avatarShape: String? = nil
    var avatarPalette: String? = nil
    var isLoaded = true
    var size: CGFloat = 34
    var motionState: ScienceAvatarMotionState = .idle
    var animate = false
    var doneTrigger: UInt64 = 0
    private var resolvedShape: ScienceAvatarShape {
        ScienceAvatarPresentation.shape(rawValue: avatarShape, identity: identity ?? name)
    }
    private var resolvedPalette: ScienceAvatarPalette {
        ScienceAvatarPresentation.palette(rawValue: avatarPalette, legacyColor: hexColor)
    }
    var body: some View {
        if isLoaded {
            ScienceAvatar(
                shape: resolvedShape.rawValue,
                palette: resolvedPalette.id,
                size: size,
                state: motionState,
                animate: animate,
                doneTrigger: doneTrigger
            )
            .accessibilityLabel("\(name) avatar, \(resolvedShape.title) character, \(resolvedPalette.name) palette")
        } else {
            Circle().fill(Color.secondary.opacity(0.12))
                .frame(width: size, height: size)
                .accessibilityLabel("\(name) avatar loading")
        }
    }
}

struct ScienceAvatarHeaderMotionSignal: Equatable {
    let activeTurnID: String?
    let state: ScienceAvatarMotionState
    let isPresented: Bool
    let reduceMotion: Bool
}

enum ScienceAvatarObservedTurnStatus: Equatable {
    case inProgress, completed, interrupted, failed, unknown

    init(rawValue: String?) {
        switch rawValue {
        case "inProgress": self = .inProgress
        case "completed": self = .completed
        case "interrupted": self = .interrupted
        case "failed": self = .failed
        default: self = .unknown
        }
    }
}

struct ScienceAvatarHeaderMotionOutput: Equatable {
    var state: ScienceAvatarMotionState = .idle
    var animate = false
    var doneTrigger: UInt64 = 0
}

struct ScienceAvatarHeaderMotionReducer: Equatable {
    private(set) var trackedActiveTurnID: String?
    private var settledTurnIDs: [String] = []
    private var pendingDoneTurnID: String?
    private(set) var output = ScienceAvatarHeaderMotionOutput()

    mutating func reduce(
        activeTurnID: String?,
        trackedTurnStatus: ScienceAvatarObservedTurnStatus,
        isPresented: Bool,
        reduceMotion: Bool,
        activeState: ScienceAvatarMotionState = .working
    ) {
        if let trackedActiveTurnID, trackedActiveTurnID != activeTurnID {
            switch trackedTurnStatus {
            case .completed:
                settle(trackedActiveTurnID)
                if !reduceMotion { pendingDoneTurnID = trackedActiveTurnID }
            case .interrupted, .failed:
                settle(trackedActiveTurnID)
            case .inProgress, .unknown:
                // Losing lifecycle continuity through a reconnect or an
                // unknown old-host projection must not fabricate completion.
                self.trackedActiveTurnID = nil
            }
        }

        if let activeTurnID, !settledTurnIDs.contains(activeTurnID) {
            trackedActiveTurnID = activeTurnID
        }

        let canAnimate = isPresented && !reduceMotion
        if canAnimate, pendingDoneTurnID != nil {
            output.doneTrigger &+= 1
            pendingDoneTurnID = nil
        }
        output.state = trackedActiveTurnID == activeTurnID && activeTurnID != nil ? activeState : .idle
        output.animate = canAnimate
    }

    private mutating func settle(_ turnID: String) {
        trackedActiveTurnID = nil
        guard !settledTurnIDs.contains(turnID) else { return }
        settledTurnIDs.append(turnID)
        if settledTurnIDs.count > 16 { settledTurnIDs.removeFirst(settledTurnIDs.count - 16) }
    }
}

struct ConversationAvatarHeader: View {
    let name: String
    let identity: String
    let hexColor: String?
    let avatarShape: String?
    let avatarPalette: String?
    let motion: ScienceAvatarHeaderMotionOutput
    var isLoaded = true

    private var resolvedShape: ScienceAvatarShape {
        ScienceAvatarPresentation.shape(rawValue: avatarShape, identity: identity)
    }
    private var resolvedPalette: ScienceAvatarPalette {
        ScienceAvatarPresentation.palette(rawValue: avatarPalette, legacyColor: hexColor)
    }

    var body: some View {
        HStack(spacing: 7) {
            ChatAvatar(
                name: name,
                identity: identity,
                hexColor: hexColor,
                avatarShape: avatarShape,
                avatarPalette: avatarPalette,
                isLoaded: isLoaded,
                size: 32,
                motionState: motion.state,
                animate: motion.animate,
                doneTrigger: motion.doneTrigger
            )
            .accessibilityHidden(true)
            Text(name)
                .font(.headline)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoaded ? "\(name), \(resolvedShape.title) character, \(resolvedPalette.name) palette" : name)
        .accessibilityValue(motion.state.title)
        .accessibilityIdentifier("conversation-avatar-header")
    }
}

struct AttentionRow: View {
    @ObservedObject var model: ConnectionModel
    let request: AttentionRequest
    @State private var answers: [String: String] = [:]
    @State private var questionIndex = 0
    @State private var choices: [PhoneApprovalChoice] = []
    @State private var fields: [PhoneApprovalField] = []
    @State private var permissionDetails: [String] = []
    @State private var unavailableReason: String?
    @State private var validChoices: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let saved = model.savedDecisions[request.id] {
                Text("A reply is saved. Check whether it was received.")
                Button("Check saved reply") { Task { await model.resolve(request, decision: saved.decision) } }.frame(minHeight: 44)
            } else if request.isQuestion {
                VStack(alignment: .leading, spacing: 8) {
                QuestionNavigation(index: $questionIndex, count: request.params.questions?.count ?? 0)
                ForEach(Array((request.params.questions ?? []).enumerated()).filter { $0.offset == questionIndex }, id: \.element.id) { _, question in
                    Text(question.question).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    if question.multiSelect == true {
                        QuestionMultiChoice(question: question, draft: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0; save() }))
                    } else {
                    ForEach(question.options ?? [], id: \.label) { option in
                        ConversationChoice(title: option.label, detail: option.description, selected: answers[question.id] == option.label) {
                            answers[question.id] = option.label; save()
                        }
                    }
                    if question.isSecret == true {
                        SecureField("Type an answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0 }))
                    } else { TextField("Type an answer", text: Binding(get: { answers[question.id] ?? "" }, set: { answers[question.id] = $0; save() }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(question.question) }
                    }
                }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if request.params.isBlocking != false {
                    Text("Answer needed to continue").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                Button("Reply") { Task { await model.resolve(request, decision: "respond", answers: answers) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.previewMode || (request.params.questions ?? []).contains { $0.answers(from: answers[$0.id] ?? "").isEmpty })
                if request.params.isBlocking == false {
                    Button("Skip") { Task { await model.resolve(request, decision: "skip", answers: [:]) } }.buttonStyle(.bordered).disabled(model.previewMode)
                }
                }.controlSize(.regular).frame(minHeight: 44)
            } else {
                Text("Permission requested").font(.headline)
                if let detail = request.computerAction?.detail {
                    ScrollView { Text(detail).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                        .frame(maxHeight: 180).fixedSize(horizontal: false, vertical: true)
                }
                if let reason = request.params.reason { Text(reason) }
                if let command = request.params.command { Text(command).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                if let path = request.params.filePath ?? request.params.cwd { Text(path).font(.caption).textSelection(.enabled) }
                ForEach(request.params.changes ?? [], id: \.path) { change in
                    Text(change.path).font(.caption).textSelection(.enabled)
                }
                if let message = request.params.message { Text(message) }
                ForEach(permissionDetails, id: \.self) { detail in
                    Text(detail).font(.subheadline).textSelection(.enabled)
                }
                if let url = request.elicitationURL {
                    Link(destination: url) {
                        Label("Open " + (url.host ?? "service"), systemImage: "arrow.up.right.square")
                    }.frame(minHeight: 44).accessibilityIdentifier("approval-service-link")
                    Text("Complete the request in your browser, then return here to continue.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(fields) { field in
                    PhoneApprovalFieldView(field: field, answer: Binding(
                        get: { answers[field.id] ?? field.defaultValue ?? "" },
                        set: { answers[field.id] = $0 }
                    ))
                }
                if let reason = unavailableReason {
                    Text(reason).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(choices) { choice in
                        ConversationChoice(title: choice.title, detail: choice.detail) {
                            Task { await model.resolve(request, choice: choice, answers: answers) }
                        }
                        .disabled(model.previewMode || !validChoices.contains(choice.id))
                        .accessibilityIdentifier("approval-\(choice.id)-\(request.id)")
                    }
                }

            }
            if model.resolving.contains(request.id) { ProgressView("Sending reply…") }
            if let error = model.attentionErrors[request.id] { FailureDetails(message: error) }
        }.disabled(model.resolving.contains(request.id) || model.accessEnded)
            .padding(.vertical, 8)
            .task(id: request.id + request.actionNonce) {
                choices = request.phoneChoices
                fields = request.elicitationFields
                permissionDetails = request.permissionDetails
                unavailableReason = request.unsupportedReason
                answers = request.isQuestion ? model.answerDraft(request.id) : [:]
                for field in fields {
                    if let value = field.defaultValue { answers[field.id] = value }
                }
                validateAnswers()
            }
            .onChange(of: answers) { _ in validateAnswers() }
    }
    private func validateAnswers() {
        validChoices = Set(choices.filter { request.canSubmit(choice: $0, answers: answers) }.map(\.id))
    }
    private func save() { let secretIDs = Set((request.params.questions ?? []).filter { $0.isSecret == true }.map(\.id)); model.saveAnswerDraft(answers.filter { !secretIDs.contains($0.key) }, id: request.id) }
}

private struct QuestionMultiChoice: View {
    let question: ChatQuestion
    @Binding var draft: String
    @State private var selected: Set<String> = []
    @State private var other = ""
    @State private var savedDraft: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(question.options ?? [], id: \.label) { option in
                ConversationChoice(title: option.label, detail: option.description, selected: selected.contains(option.label)) {
                    if selected.contains(option.label) { selected.remove(option.label) } else { selected.insert(option.label) }
                    save()
                }.accessibilityIdentifier("question-option-\(question.id)-\(option.label)")
            }
            TextField("Another answer", text: $other, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("question-other-" + question.id)
                .onChange(of: other) { _, _ in save() }
        }.task(id: question.id) { restore() }
            .onChange(of: draft) { _, value in if value != savedDraft { restore() } }
    }
    private func restore() {
        let values = question.answers(from: draft)
        let labels = Set((question.options ?? []).map(\.label))
        selected = Set(values.filter { labels.contains($0) })
        other = values.filter { !labels.contains($0) }.joined(separator: "\n")
    }
    private func save() {
        var values = (question.options ?? []).map(\.label).filter { selected.contains($0) }
        let freeText = other.trimmingCharacters(in: .whitespacesAndNewlines)
        if !freeText.isEmpty { values.append(freeText) }
        if let data = try? JSONEncoder().encode(values) {
            let value = String(decoding: data, as: UTF8.self)
            savedDraft = value
            draft = value
        }
    }
}

/// Fields stay in the conversation's existing scroll surface and use native
/// controls, so keyboard, VoiceOver and Dynamic Type behave like other replies.
private struct PhoneApprovalFieldView: View {
    let field: PhoneApprovalField
    @Binding var answer: String
    @State private var selected: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title + (field.required ? " (required)" : "")).font(.subheadline.weight(.semibold))
            if let detail = field.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            switch field.kind {
            case .boolean:
                Picker(field.title, selection: $answer) {
                    Text("Choose").tag("")
                    Text("Yes").tag("true")
                    Text("No").tag("false")
                }.pickerStyle(.menu)
            case .choice:
                Picker(field.title, selection: $answer) {
                    Text("Choose").tag("")
                    ForEach(field.options, id: \.self) { option in Text(field.optionTitles[option] ?? option).tag(option) }
                }.pickerStyle(.menu)
            case .multiChoice:
                ForEach(field.options, id: \.self) { option in
                    Toggle(field.optionTitles[option] ?? option, isOn: Binding(
                        get: { selected.contains(option) },
                        set: { checked in
                            var values = selected
                            if checked { values.insert(option) } else { values.remove(option) }
                            selected = values
                            if let data = try? JSONEncoder().encode(values.sorted()) { answer = String(decoding: data, as: UTF8.self) }
                        }
                    ))
                }
            case .text, .number, .integer:
                if field.secret {
                    SecureField(field.title, text: $answer).textFieldStyle(.roundedBorder)
                } else {
                    TextField(field.title, text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
                        .keyboardType(field.kind == .text ? .default : .numbersAndPunctuation)
                }
            }
        }.accessibilityIdentifier("approval-field-" + field.id)
            .task(id: answer) {
                if field.kind == .multiChoice {
                    selected = Set((try? JSONDecoder().decode([String].self, from: Data(answer.utf8))) ?? [])
                }
            }
    }
}

enum PhotoViewerRouting {
    nonisolated static func isImage(_ file: ConversationFile) -> Bool {
        isImage(mimeType: file.mimeType)
    }

    nonisolated static func isImage(mimeType: String?) -> Bool {
        mimeType?.lowercased().hasPrefix("image/") == true
    }
}

private struct PhotoViewerRequest: Hashable, Sendable {
    let scope: UUID
    let sourceID: String
    let name: String
    let mimeType: String
    let state: String
    let revision: String
}

private struct PhotoViewerItem: Identifiable {
    let id: String
    let name: String
    let mimeType: String
    let sourceFile: ConversationFile?
    let localData: Data?
    var localRevision: String? = nil
}

private struct PhotoViewerPage: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let item: PhotoViewerItem
    let onVerifiedData: (String, Data?) -> Void
    let copyImage: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var zoomScale: CGFloat = 1
    @State private var loadedRequest: PhotoViewerRequest?

    private var request: PhotoViewerRequest {
        PhotoViewerRequest(
            scope: model.imagePreviewScope,
            sourceID: item.id,
            name: item.name,
            mimeType: item.mimeType,
            state: item.sourceFile?.state ?? "local",
            revision: item.localRevision ?? item.sourceFile?.updatedAt ?? "local"
        )
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                PhotoZoomView(
                    image: image,
                    imageID: request.sourceID + ":" + (loadedRequest?.revision ?? request.revision),
                    zoomScale: $zoomScale,
                    reduceMotion: reduceMotion,
                    preservePosition: item.localRevision != nil
                )
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("photo-viewer-image:\(item.id)")
                .accessibilityLabel(item.name)
                .accessibilityValue("Zoom \(Int((zoomScale * 100).rounded()))%")
                .accessibilityHint("Pinch to zoom. Double-tap to zoom or reset. Long-press for actions.")
                .contextMenu { Button("Copy image", systemImage: "doc.on.doc") { copyImage() } }
            } else if let failure {
                VStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Photo unavailable")
                        .font(.headline)
                    Text(failure)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(24)
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("photo-viewer-error")
            } else {
                ProgressView("Loading photo…")
                    .tint(.white)
                    .foregroundStyle(.white)
                .accessibilityIdentifier("photo-viewer-loading")
            }
        }
        .task(id: request) { await load(request) }
        .onChange(of: request) { previous, next in
            if previous.sourceID != next.sourceID || previous.scope != next.scope {
                zoomScale = 1
                image = nil
            }
            failure = nil
        }
        .onDisappear {
            image = nil
            onVerifiedData(item.id, nil)
        }
    }

    private func load(_ request: PhotoViewerRequest) async {
        if loadedRequest?.sourceID != request.sourceID || loadedRequest?.scope != request.scope { image = nil }
        failure = nil
        guard PhotoViewerRouting.isImage(mimeType: request.mimeType) else {
            failure = "This file is not an image."
            return
        }
        if let sourceFile = item.sourceFile, sourceFile.state != "available" {
            failure = "This image is no longer available."
            return
        }
        do {
            let data: Data
            if let localData = item.localData {
                guard localData.count <= 8 * 1024 * 1024, !localData.isEmpty else { throw FileFailure.tooLarge }
                try ConversationFile.validateContent(localData, mime: request.mimeType)
                data = localData
            } else if let sourceFile = item.sourceFile {
                data = try await model.download(sourceFile, chat: chat)
            } else {
                throw FileFailure.integrity
            }
            try Task.checkCancellation()
            guard model.imagePreviewScope == request.scope else { return }
            let decodeTask: Task<UIImage?, Never> = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil }
                return PhotoViewerImage.decode(data)
            }
            let decoded = await withTaskCancellationHandler(operation: {
                await decodeTask.value
            }, onCancel: {
                decodeTask.cancel()
            })
            try Task.checkCancellation()
            guard model.imagePreviewScope == request.scope else { return }
            guard let decoded else { throw FileFailure.unsupported }
            image = decoded
            loadedRequest = request
            onVerifiedData(item.id, data)
        } catch is CancellationError {
            // The viewer was dismissed or its conversation scope changed.
        } catch {
            guard !Task.isCancelled, model.imagePreviewScope == request.scope else { return }
            image = nil
            failure = "This image could not be verified or decoded. Close and try again."
            onVerifiedData(item.id, nil)
        }
    }
}

struct PhotoViewer: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    private let items: [PhotoViewerItem]
    @State private var selectedIndex: Int
    @Environment(\.dismiss) private var dismiss
    var onClose: (() -> Void)? = nil
    var showsHeader = true
    @State private var verifiedData: [String: Data] = [:]
    @State private var copyStatus: String?

    init(model: ConnectionModel, chat: ChatSummary, file: ConversationFile, galleryFiles: [ConversationFile] = [], initialFileID: String? = nil,
         onClose: (() -> Void)? = nil, showsHeader: Bool = true) {
        self.model = model
        self.chat = chat
        self.onClose = onClose
        self.showsHeader = showsHeader
        let sources = galleryFiles.isEmpty ? [file] : ConversationAttachmentGallery.imageFiles(galleryFiles)
        let bounded = Self.boundedItems(sources.map { PhotoViewerItem(id: $0.id, name: $0.name, mimeType: $0.mimeType ?? "", sourceFile: $0, localData: nil) }, initialID: initialFileID ?? file.id)
        self.items = bounded.items
        _selectedIndex = State(initialValue: bounded.index)
    }

    init(model: ConnectionModel, chat: ChatSummary, galleryFiles: [ConversationFile], initialFileID: String) {
        self.model = model
        self.chat = chat
        let sources = ConversationAttachmentGallery.imageFiles(galleryFiles)
        let fallback = sources.first
        let bounded = Self.boundedItems(sources.map { PhotoViewerItem(id: $0.id, name: $0.name, mimeType: $0.mimeType ?? "", sourceFile: $0, localData: nil) }, initialID: initialFileID)
        self.items = bounded.items.isEmpty && fallback == nil ? [] : bounded.items
        _selectedIndex = State(initialValue: bounded.index)
    }

    init(model: ConnectionModel, chat: ChatSummary, name: String, mimeType: String, sourceID: String, localData: Data?, file: ConversationFile?, revision: String? = nil,
         onClose: (() -> Void)? = nil, showsHeader: Bool = true) {
        self.model = model
        self.chat = chat
        self.onClose = onClose
        self.showsHeader = showsHeader
        self.items = [PhotoViewerItem(id: sourceID, name: name, mimeType: mimeType, sourceFile: file, localData: localData, localRevision: revision)]
        _selectedIndex = State(initialValue: 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if items.isEmpty {
                ContentUnavailableView("Photo unavailable", systemImage: "photo", description: Text("This image is no longer available."))
                    .foregroundStyle(.white)
            } else {
                TabView(selection: $selectedIndex) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PhotoViewerPage(model: model, chat: chat, item: item, onVerifiedData: { id, data in
                            if let data { verifiedData[id] = data } else { verifiedData.removeValue(forKey: id) }
                        }, copyImage: { copyImage(for: item.id) })
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsHeader {
                HStack(alignment: .top, spacing: 12) {
                if let item = currentItem {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("photo-viewer-name")
                }
                Spacer(minLength: 0)
                if items.count > 1 {
                    Text("\(selectedIndex + 1) of \(items.count)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("photo-viewer-position")
                }
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .accessibilityLabel("Close photo viewer")
                .accessibilityIdentifier("photo-viewer-close")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.black.opacity(0.78))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let copyStatus {
                Text(copyStatus)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("photo-viewer-copy-status")
            }
        }
        .onChange(of: selectedIndex) { _, _ in copyStatus = nil }
        .onDisappear {
            verifiedData.removeAll()
        }
    }

    private var currentItem: PhotoViewerItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    private func copyImage(for id: String) {
        guard let data = verifiedData[id], let item = items.first(where: { $0.id == id }),
              let type = UTType(mimeType: item.mimeType), type.conforms(to: .image) else {
            copyStatus = "Copy unavailable"
            return
        }
        UIPasteboard.general.setItems([[type.identifier: data]], options: [.expirationDate: Date().addingTimeInterval(300)])
        copyStatus = "Image copied"
    }

    private static func boundedItems(_ items: [PhotoViewerItem], initialID: String) -> (items: [PhotoViewerItem], index: Int) {
        guard items.count > 24 else {
            return (items, max(0, items.firstIndex(where: { $0.id == initialID }) ?? 0))
        }
        var bounded = Array(items.prefix(24))
        if let initial = items.first(where: { $0.id == initialID }), !bounded.contains(where: { $0.id == initialID }) {
            bounded[bounded.count - 1] = initial
        }
        return (bounded, bounded.firstIndex(where: { $0.id == initialID }) ?? 0)
    }

}


private struct WorkspacePreviewSelection: Identifiable {
    let id: String
    let name: String
    let mimeType: String
    let data: Data
    let sha256: String
    var rootID: String? = nil
    var path: String? = nil
    var scope: String? = nil
}

/// One selected file owns its verified revision across inline and full-screen
/// presentations. Switching presentation must not discard an offered update.
@MainActor final class WorkspaceRevisionState: ObservableObject {
    @Published var currentData: Data
    @Published var currentSha256: String
    @Published var offeredData: Data?
    @Published var offeredSha256: String?
    @Published var refreshFailure: String?
    @Published var refreshing = false
    @Published var preparedText: String?
    @Published var preparingText = true
    @Published var previewTruncated = false
    var observedSequence: UInt64?
    var manualRefreshTask: Task<Void, Never>?
    private var preparedSha256: String?
    private var closed = false

    init(data: Data, sha256: String) {
        currentData = data
        currentSha256 = sha256
    }

    func prepareTextIfNeeded(mimeType: String) async {
        guard !closed, mimeType != "application/pdf", preparedSha256 != currentSha256 else { return }
        let data = currentData
        let sha256 = currentSha256
        preparingText = true
        let prepared = await Task.detached(priority: .userInitiated) { () -> (String?, Bool) in
            // TextKit must never lay out an entire multi-megabyte source on the
            // main thread. The preview is an exact prefix of the verified bytes,
            // so a selection still maps to the same UTF-8 source offsets.
            guard String(data: data, encoding: .utf8) != nil else { return (nil, false) }
            let limit = 128 * 1024
            guard data.count > limit else { return (String(data: data, encoding: .utf8), false) }
            guard mimeType != "text/html" else { return (nil, true) }
            var end = limit
            while end > 0, String(data: data.prefix(end), encoding: .utf8) == nil { end -= 1 }
            return (String(data: data.prefix(end), encoding: .utf8), true)
        }.value
        guard !Task.isCancelled, !closed, currentSha256 == sha256 else { return }
        preparedText = prepared.0
        previewTruncated = prepared.1
        preparedSha256 = sha256
        preparingText = false
    }

    @discardableResult func checkForRevision(refresh: (() async throws -> Data)?,
                          onRevision: ((String) async -> Void)?, failureMessage: String) async -> Bool {
        guard let refresh, !closed, !refreshing else { return false }
        refreshing = true; refreshFailure = nil
        defer { refreshing = false }
        do {
            let data = try await refresh()
            guard !Task.isCancelled, !closed else { return false }
            let sha256 = await Task.detached(priority: .userInitiated) { ConversationFile.digest(data) }.value
            guard !Task.isCancelled, !closed else { return false }
            if sha256 != currentSha256 {
                offeredData = data; offeredSha256 = sha256
                await onRevision?(sha256)
            } else { offeredData = nil; offeredSha256 = nil }
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled, !closed else { return false }
            refreshFailure = failureMessage
            return true
        }
    }

    func observe(sequence: UInt64, refresh: (() async throws -> Data)?,
                 onRevision: ((String) async -> Void)?, failureMessage: String) async {
        guard !closed, refresh != nil else { return }
        if observedSequence == nil { observedSequence = sequence; return }
        guard sequence > (observedSequence ?? 0) else { return }
        // A newer SwiftUI task cancels the previous check before its defer
        // clears `refreshing`. Wait for that cleanup, then check the newest
        // sequence; never mark a sequence observed when its check was skipped.
        while refreshing {
            do { try await Task.sleep(for: .milliseconds(30)) }
            catch { return }
            guard !closed else { return }
            if sequence <= (observedSequence ?? 0) { return }
        }
        guard !Task.isCancelled, !closed else { return }
        let checked = await checkForRevision(refresh: refresh, onRevision: onRevision, failureMessage: failureMessage)
        guard checked, !Task.isCancelled, !closed, sequence > (observedSequence ?? 0) else { return }
        observedSequence = sequence
    }

    func showOfferedRevision() {
        guard !closed, let data = offeredData, let sha256 = offeredSha256 else { return }
        preparingText = true
        preparedText = nil
        previewTruncated = false
        currentData = data; currentSha256 = sha256
        offeredData = nil; offeredSha256 = nil
    }

    func close() { closed = true; manualRefreshTask?.cancel(); manualRefreshTask = nil }
}

@MainActor private final class WorkspaceTextAnnotationDraft: ObservableObject {
    @Published var selectedRange: NSRange?
    @Published var selectionResetID = UUID()
    @Published var editingSelection = false
    @Published var note = ""
    @Published var error: String?

    func clearSelection(discardNote: Bool) {
        selectedRange = nil
        selectionResetID = UUID()
        editingSelection = false
        error = nil
        if discardNote { note = "" }
    }

    func reset(note: String = "") {
        clearSelection(discardNote: true)
        self.note = note
    }
}

struct ArtifactPreviewContext {
    let projectID: String
    let conversationID: String
    let rootID: String
    let path: String
    let scope: String
}

/// Keep the destination with the sheet's identity so its first presentation
/// cannot capture a filename or attachment filter from an earlier render.
struct WorkspaceBrowserRequest: Identifiable {
    let id = UUID()
    var attachmentIDs: [String]? = nil
    var initialFilePath: String? = nil
    var preferredRootID: String? = nil
    var reanchor: ArtifactAnnotation? = nil
    var replacingAnnotationID: String? = nil
}

@MainActor private final class WorkspaceMediaSelection: ObservableObject, Identifiable {
    let id: String
    let name: String
    let loader: WorkspaceMediaResourceLoader
    let asset: AVURLAsset
    @Published private(set) var player: AVPlayer?
    @Published private(set) var failure: String?
    private var monitor: Task<Void, Never>?
    private var closed = false

    init(id: String, name: String, loader: WorkspaceMediaResourceLoader) throws {
        self.id = id
        self.name = name
        self.loader = loader
        asset = try loader.asset(filename: name)
    }

    func start() {
        guard monitor == nil, !closed else { return }
        let asset = asset
        monitor = Task { [weak self] in
            do {
                guard try await asset.load(.isPlayable) else {
                    self?.failure = "This audio or video format cannot be played on this device."
                    return
                }
                guard !Task.isCancelled, self?.closed == false else { return }
                let item = AVPlayerItem(asset: asset)
                self?.player = AVPlayer(playerItem: item)
                while !Task.isCancelled {
                    if self?.reportFailureIfNeeded(for: item) == true { return }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, self?.closed == false else { return }
                self?.failure = self?.loader.fileChanged == true
                    ? "File changed. Close and reopen the preview."
                    : "This file could not be streamed. Check your Mac connection and try again."
            }
        }
    }

    private func reportFailureIfNeeded(for item: AVPlayerItem) -> Bool {
        guard item.status == .failed else { return false }
        failure = loader.fileChanged
            ? "File changed. Close and reopen the preview."
            : "Playback stopped. Check your Mac connection or try a different file."
        player?.pause()
        player = nil
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        monitor?.cancel()
        monitor = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        loader.cancelAll()
    }

    deinit { loader.cancelAll() }
}

struct WorkspaceBrowser: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let attachmentIDs: [String]?
    var initialFilePath: String? = nil
    var preferredRootID: String? = nil
    var reanchor: ArtifactAnnotation? = nil
    var replacingAnnotationID: String? = nil
    var onClose: (() -> Void)? = nil
    @State private var openedInitialFile = false
    @Environment(\.dismiss) private var dismiss
    @State private var response: WorkspaceRootsResponse?
    @State private var selectedRootID: String?
    @State private var directoryPath = ""
    @State private var directory: WorkspaceDirectoryPage?
    @State private var missingDirectory = false
    @State private var git: WorkspaceGitStatusResponse?
    @State private var viewMode = "all"
    @State private var showHidden = false
    @State private var loadingRequests: Set<UUID> = []
    @State private var rootsLoadingID: UUID?
    @State private var locationGeneration = UUID()
    @State private var rootsRequestID = UUID()
    @State private var loadedRootsScope: String?
    @State private var directoryRequestID = UUID()
    @State private var gitRequestID = UUID()
    @State private var diffRequestID = UUID()
    @State private var fileRequestID = UUID()
    @State private var attachmentRequestID = UUID()
    @State private var failure: String?
    @State private var selection: WorkspacePreviewSelection?
    @State private var documentSelection: WorkspacePreviewSelection?
    @State private var previewRevision: WorkspaceRevisionState?
    @State private var mediaSelection: WorkspaceMediaSelection?
    @State private var attachmentPhoto: ConversationFile?
    @State private var attachmentSelection: ConversationFile?
    @State private var attachmentData: Data?
    @State private var attachmentDigest: String?
    @State private var selectedDiff: WorkspaceGitChange?
    @State private var diffChoice: WorkspaceGitChange?
    @State private var diffText: String?
    @State private var expandedPreview = false
    @State private var collapsingPreview = false
    @State private var pdfSession = PDFPreviewSession()
    @State private var modelSession: WorkspaceModelPreviewSession?
    @StateObject private var textAnnotationDraft = WorkspaceTextAnnotationDraft()

    private var loading: Bool { !loadingRequests.isEmpty }
    private var selectedRoot: WorkspaceRoot? { response?.roots.first(where: { $0.id == selectedRootID }) }
    private var visibleAttachments: [ConversationFile] {
        let files = response?.attachments ?? []
        guard let attachmentIDs else { return files }
        return files.filter { attachmentIDs.contains($0.id) }
    }
    // Hidden-file changes are explicitly reloaded by the action below. Keeping
    // this task identity scoped to navigation prevents one tap from starting
    // both the implicit task and the explicit refresh.
    private var directoryTaskID: String { "\(model.assignmentScope):\(selectedRootID ?? ""):\(directoryPath)" }
    private var hasPreview: Bool {
        selection != nil || documentSelection != nil || mediaSelection != nil ||
        attachmentPhoto != nil || (attachmentSelection != nil && attachmentData != nil && attachmentDigest != nil) ||
        (selectedDiff != nil && diffText != nil)
    }
    private var previewName: String {
        selection?.name ?? documentSelection?.name ?? mediaSelection?.name ?? attachmentPhoto?.name ??
        attachmentSelection?.name ?? selectedDiff?.path ?? "Preview"
    }

    var body: some View {
        Group {
            if hasPreview {
                inlinePreview
            } else {
                NavigationStack {
                    VStack(spacing: 0) {
                        if onClose != nil {
                            HStack {
                                Text("Files").font(.headline)
                                Spacer()
                                Button("Chat", systemImage: "xmark") { onClose?() }
                                    .frame(minWidth: 44, minHeight: 44)
                                    .accessibilityIdentifier("workspace-close")
                            }
                            .padding(.horizontal, 12)
                        }
                Picker("Files view", selection: $viewMode) {
                    Text("All files").tag("all")
                    Text("Modified").tag("modified")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)
                .accessibilityIdentifier("workspace-view-picker")
                if let response, response.roots.count > 1 {
                    Menu {
                        ForEach(response.roots) { root in
                            WorkspaceRootMenuButton(root: root) { selectRoot($0) }
                        }
                    } label: {
                        HStack {
                            Label(selectedRoot?.label ?? "Choose location", systemImage: "folder")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .accessibilityIdentifier("workspace-root-picker")
                }
                if let failure {
                    VStack(spacing: 12) {
                        ContentUnavailableView("Files unavailable", systemImage: "externaldrive.badge.xmark", description: Text(failure))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Files unavailable. \(failure)")
                            .accessibilityIdentifier("workspace-unavailable")
                        Button("Try again") { Task { await retryWorkspace() } }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("workspace-retry")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewMode == "modified" {
                    modifiedView
                } else {
                    allFilesView
                }
                    }
                    .navigationTitle("Files")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if onClose == nil {
                            ToolbarItem(placement: .cancellationAction) {
                                WorkspaceBrowserDoneButton { dismiss() }
                            }
                        }
                    }
                }
            }
        }
            .task(id: model.assignmentScope) {
                let scope = model.assignmentScope
                // Switching between the list and an inline preview can remount
                // this task. Only a pairing change should reset the selection.
                guard loadedRootsScope != scope || response == nil else { return }
                invalidateLocation()
                response = nil; selectedRootID = nil; directoryPath = ""; directory = nil; git = nil
                if await loadRoots() {
                    loadedRootsScope = scope
                    if viewMode == "modified" { await loadGit() }
                }
            }
            .task(id: directoryTaskID) {
                guard viewMode == "all", selectedRoot?.isDirectory == true else { return }
                guard await loadDirectory(reset: true) else { return }
                await openInitialFileIfNeeded()
            }
            .onChange(of: viewMode) { _, next in
                // The first roots request belongs to Files, not either tab.
                // Keep it alive when Modified is selected before roots arrive.
                invalidateLocation(preserveRoots: rootsLoadingID != nil)
                failure = nil
                if next == "modified" { git = nil; Task { await loadGit() } }
                else if selectedRoot?.isDirectory == true { Task { await loadDirectory(reset: true) } }
            }
            .onDisappear {
                // A full-screen cover temporarily hides the browser; closing
                // Files or leaving the conversation must release its work.
                if !expandedPreview {
                    mediaSelection?.close()
                    previewRevision?.close()
                    modelSession?.close()
                }
            }
            .fullScreenCover(isPresented: $expandedPreview) {
                VStack(spacing: 0) {
                    HStack {
                        Button("Show in chat", systemImage: "arrow.down.right.and.arrow.up.left") {
                            pdfSession.capture()
                            collapsingPreview = true
                            expandedPreview = false
                        }
                        .accessibilityIdentifier("workspace-preview-collapse")
                        Spacer()
                        Text(previewName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    previewContent
                }
                .onDisappear {
                    // A parent navigation can dismiss the cover while the
                    // browser's onDisappear is suppressed by presentation.
                    // Only the explicit collapse keeps the selected work.
                    if !collapsingPreview {
                        mediaSelection?.close()
                        previewRevision?.close()
                        modelSession?.close()
                    }
                    collapsingPreview = false
                }
            }
            .confirmationDialog("Choose diff", isPresented: Binding(get: { diffChoice != nil }, set: { if !$0 { diffChoice = nil } })) {
                if let change = diffChoice {
                    Button("Staged changes") { loadDiff(change, staged: true) }
                    Button("Unstaged changes") { loadDiff(change, staged: false) }
                }
            } message: {
                Text("This file has both staged and unstaged changes.")
            }
    }

    private var inlinePreview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { closePreview() } label: {
                    Label("Files", systemImage: "chevron.left")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("workspace-preview-back")
                Text(previewName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                Button("Full screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    pdfSession.capture()
                    expandedPreview = true
                }
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("workspace-preview-expand")
            }
            .padding(.horizontal, 12)
            .background(Color(uiColor: .secondarySystemBackground))
            // The full-screen cover owns the preview while expanded. PDFKit,
            // WebKit and large text/diff layouts must not stay mounted twice.
            if !expandedPreview { previewContent }
        }
    }

    @ViewBuilder private var previewContent: some View {
        if let item = selection {
            if let context = annotationContext(for: item), let previewRevision {
                let replacement = reanchorDraft(for: item)
                WorkspaceImagePreview(model: model, chat: chat, item: item, context: context,
                                      revision: previewRevision,
                                      refresh: revisionRefresh(for: item),
                                      onRevision: revisionNotice(for: item),
                                      refreshSequence: model.snapshots[chat.id]?.lastSequence,
                                      initialNote: replacement?.note ?? "", onClose: closePreview) { annotation in
                    try model.stageAnnotation(annotation, chat: chat, expectedScope: context.scope,
                                              replacing: replacement?.id)
                    if expandedPreview {
                        pdfSession.capture()
                        collapsingPreview = true; expandedPreview = false
                    }
                }
            } else {
                PhotoViewer(model: model, chat: chat, name: item.name, mimeType: item.mimeType,
                            sourceID: item.id, localData: item.data, file: nil,
                            onClose: closePreview, showsHeader: false)
            }
        } else if let file = attachmentPhoto {
            PhotoViewer(model: model, chat: chat, file: file,
                        galleryFiles: ConversationAttachmentGallery.imageFiles(visibleAttachments),
                        initialFileID: file.id, onClose: closePreview, showsHeader: false)
        } else if let item = documentSelection {
            if WorkspaceModelPreview.supports(item.name) {
                WorkspaceModelPreview(name: item.name, data: item.data, revision: item.sha256,
                                      session: modelSession,
                                      onClose: closePreview)
            } else if WorkspacePublicationPreview.supports(item.name) {
                WorkspacePublicationPreview(name: item.name, data: item.data,
                                            origin: "workspace:\(model.assignmentScope):\(chat.id):\(item.id)",
                                            onClose: closePreview)
            } else if let previewRevision {
                let context = annotationContext(for: item)
                let replacement = reanchorDraft(for: item)
                WorkspaceDocumentPreview(name: item.name, mimeType: item.mimeType,
                                         revision: previewRevision, draft: textAnnotationDraft,
                                         pdfSession: pdfSession,
                                         annotationContext: context, onAnnotation: { annotation in
                    guard let context else { throw FileFailure.integrity }
                    try model.stageAnnotation(annotation, chat: chat, expectedScope: context.scope,
                                              replacing: replacement?.id)
                    if expandedPreview {
                        pdfSession.capture()
                        collapsingPreview = true; expandedPreview = false
                    }
                }, refresh: revisionRefresh(for: item), onRevision: revisionNotice(for: item),
                                         refreshSequence: model.snapshots[chat.id]?.lastSequence,
                                         onClose: closePreview)
            }
        } else if let item = mediaSelection {
            WorkspaceMediaPreview(selection: item, onClose: closePreview)
        } else if let file = attachmentSelection, let data = attachmentData,
                  let digest = attachmentDigest {
            if WorkspaceModelPreview.supports(file.name) {
                WorkspaceModelPreview(name: file.name, data: data, revision: digest,
                                      session: modelSession, onClose: closePreview)
            } else if WorkspacePublicationPreview.supports(file.name) {
                WorkspacePublicationPreview(name: file.name, data: data,
                                            origin: "attachment:\(model.assignmentScope):\(chat.id):\(file.id)",
                                            onClose: closePreview)
            } else if let previewRevision {
                WorkspaceDocumentPreview(name: file.name, mimeType: file.mimeType ?? "application/octet-stream",
                                         revision: previewRevision, draft: textAnnotationDraft,
                                         pdfSession: pdfSession,
                                         onClose: closePreview)
            }
        } else if let change = selectedDiff, let diffText {
            WorkspaceDiffPreview(path: change.path, state: change.state, diff: diffText,
                                 onClose: closePreview)
        }
    }

    private func closePreview() {
        mediaSelection?.close()
        previewRevision?.close()
        modelSession?.close()
        modelSession = nil
        pdfSession = PDFPreviewSession()
        expandedPreview = false
        fileRequestID = UUID(); attachmentRequestID = UUID()
        textAnnotationDraft.reset()
        selection = nil; documentSelection = nil; previewRevision = nil; mediaSelection = nil
        attachmentPhoto = nil; attachmentSelection = nil; attachmentData = nil; attachmentDigest = nil
        diffRequestID = UUID(); selectedDiff = nil; diffText = nil
    }

    @ViewBuilder private var allFilesView: some View {
        if loading && directory == nil && visibleAttachments.isEmpty { ProgressView("Loading files…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        else {
            List {
                if loading && directory != nil {
                    ProgressView("Loading files…")
                        .accessibilityIdentifier("workspace-refreshing")
                }
                if let root = selectedRoot {
                    if !directoryPath.isEmpty {
                        Button { navigate(to: directory?.parentPath ?? "") } label: { Label("Back", systemImage: "chevron.left") }
                            .accessibilityIdentifier("workspace-back")
                    }
                    if root.isDirectory && directoryPath.isEmpty {
                        Button(action: toggleHiddenFiles) {
                            HStack(spacing: 12) {
                                Label("Show hidden files", systemImage: "eye")
                                Spacer(minLength: 12)
                                if showHidden {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .accessibilityIdentifier("workspace-hidden-toggle")
                        .accessibilityValue(showHidden ? "On" : "Off")
                        .accessibilityHint("Reloads this folder with hidden files visible")
                        .accessibilityAddTraits(showHidden ? .isSelected : [])
                    }
                    Section {
                        if root.isDirectory {
                            ForEach(directory?.entries ?? []) { entry in
                                Button { open(entry) } label: {
                                    Label(entry.name, systemImage: entry.isDirectory ? "folder" : (entry.mimeType?.hasPrefix("image/") == true ? "photo" : (Self.isMedia(entry) ? "play.rectangle" : "doc.text")))
                                }
                                .accessibilityIdentifier("workspace-\(entry.isDirectory ? "directory" : "file")-entry:\(entry.path)")
                            }
                            if let next = directory?.nextOffset {
                                Button("Load more", systemImage: "ellipsis") { Task { await loadDirectory(reset: false, offset: next) } }
                                    .accessibilityIdentifier("workspace-next-page")
                            }
                        } else {
                            Button { openRootFile(root) } label: { Label(URL(fileURLWithPath: root.path).lastPathComponent, systemImage: "doc.text") }
                                .accessibilityIdentifier("workspace-file-entry:\(root.id)")
                        }
                    } header: {
                        HStack {
                            Text(directoryPath.isEmpty ? root.label : directoryPath)
                            Spacer()
                        }
                    }
                }
                if !visibleAttachments.isEmpty {
                    Section("Conversation attachments") {
                        ForEach(visibleAttachments) { file in
                            Button { openAttachment(file) } label: { Label(file.name, systemImage: PhotoViewerRouting.isImage(file) ? "photo" : "paperclip") }
                                .accessibilityIdentifier("workspace-attachment:\(file.id)")
                        }
                    }
                }
                if let failure { Section { FailureDetails(message: failure) } }
            }
            .accessibilityIdentifier("workspace-file-list")
        }
    }

    @ViewBuilder private var modifiedView: some View {
        if let git, !git.available {
            ContentUnavailableView("Modified unavailable", systemImage: "arrow.triangle.branch", description: Text(git.detail ?? "Git status is unavailable on this host."))
                .accessibilityIdentifier("workspace-git-unavailable")
        } else if let git, git.changes.isEmpty {
            ContentUnavailableView("No modified files", systemImage: "checkmark.circle", description: Text("This workspace has no staged, unstaged, or untracked changes."))
        } else if let git {
            List(git.changes) { change in
                Button { openDiff(change) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: change.state == "renamed" ? "arrow.triangle.2.circlepath" : change.state == "conflicted" ? "exclamationmark.triangle" : "doc.text")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.path).lineLimit(1)
                            Text(change.originalPath.map { "Renamed from \($0)" } ?? (change.indexStatus != " " && change.indexStatus != "?" && change.worktreeStatus != " " ? "Staged and unstaged" : change.state.capitalized))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("workspace-modified-entry:\(change.path)")
            }
            .accessibilityIdentifier("workspace-modified-list")
        } else {
            ProgressView("Checking changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct Location: Equatable {
        let scope: String
        let generation: UUID
        let rootID: String?
        let path: String
        let mode: String
        let hidden: Bool
    }
    private var location: Location {
        Location(scope: model.assignmentScope, generation: locationGeneration,
                 rootID: selectedRootID, path: directoryPath, mode: viewMode, hidden: showHidden)
    }
    private func isCurrent(_ captured: Location) -> Bool {
        !Task.isCancelled && !model.accessEnded && captured == location
    }
    private func beginLoading() -> UUID {
        let id = UUID()
        loadingRequests.insert(id)
        return id
    }
    private func invalidateLocation(preserveRoots: Bool = false) {
        locationGeneration = UUID()
        mediaSelection?.close()
        previewRevision?.close()
        modelSession?.close()
        modelSession = nil
        pdfSession = PDFPreviewSession()
        expandedPreview = false
        if preserveRoots, let rootsLoadingID { loadingRequests = [rootsLoadingID] }
        else { rootsRequestID = UUID(); rootsLoadingID = nil; loadingRequests.removeAll() }
        directoryRequestID = UUID()
        gitRequestID = UUID()
        diffRequestID = UUID()
        fileRequestID = UUID()
        attachmentRequestID = UUID()
        textAnnotationDraft.reset()
        selectedDiff = nil; diffChoice = nil; diffText = nil
        selection = nil; documentSelection = nil; previewRevision = nil; mediaSelection = nil
        attachmentPhoto = nil; attachmentSelection = nil; attachmentData = nil; attachmentDigest = nil
    }
    private func navigate(to path: String) {
        guard directoryPath != path else { return }
        invalidateLocation()
        directoryPath = path
        directory = nil
        missingDirectory = false
        failure = nil
    }
    private func selectRoot(_ root: WorkspaceRoot) {
        invalidateLocation()
        selectedRootID = root.id
        directoryPath = ""
        directory = nil
        missingDirectory = false
        git = nil
        failure = nil
        viewMode = "all"
    }
    @discardableResult private func loadRoots() async -> Bool {
        let scope = model.assignmentScope
        let requestID = UUID()
        rootsRequestID = requestID
        let loadingID = beginLoading()
        rootsLoadingID = loadingID
        failure = nil
        defer {
            loadingRequests.remove(loadingID)
            if rootsLoadingID == loadingID { rootsLoadingID = nil }
        }
        do {
            let next = try await model.loadWorkspaceRoots(chat)
            guard !Task.isCancelled, !model.accessEnded, scope == model.assignmentScope,
                  requestID == rootsRequestID else { return false }
            let previousRootID = selectedRootID
            let previousPath = directoryPath
            invalidateLocation()
            directoryPath = ""
            directory = nil
            git = nil
            response = next
            if !openedInitialFile, let path = FileChangeSummary.relativePath(initialFilePath) {
                let root: WorkspaceRoot?
                if let preferredRootID {
                    root = next.roots.first(where: { $0.id == preferredRootID && $0.isDirectory })
                } else {
                    root = next.roots.first(where: { ["workingDirectory", "groupWorkspace", "childWorkingDirectory"].contains($0.kind) && $0.isDirectory })
                }
                guard let root else {
                    failure = "This conversation’s working folder is unavailable. Check its project or workspace settings on your Mac."
                    return true
                }
                selectedRootID = root.id
                directoryPath = path.split(separator: "/").dropLast().joined(separator: "/")
            } else if let previousRootID, next.roots.contains(where: { $0.id == previousRootID }) {
                selectedRootID = previousRootID
                directoryPath = previousPath
            } else { selectedRootID = next.roots.first?.id }
            if next.roots.isEmpty { failure = next.detail ?? "No verified workspace locations are available." }
            return true
        } catch {
            guard !Task.isCancelled, !model.accessEnded, scope == model.assignmentScope,
                  requestID == rootsRequestID else { return false }
            failure = workspaceBrowserError(error)
            return false
        }
    }
    private func retryWorkspace() async {
        failure = nil
        if missingDirectory {
            navigate(to: "")
        }
        guard await loadRoots(), failure == nil else { return }
        if viewMode == "modified" { await loadGit() }
        else if selectedRoot?.isDirectory == true {
            guard await loadDirectory(reset: true) else { return }
            await openInitialFileIfNeeded()
        }
    }
    private func openInitialFileIfNeeded() async {
        guard !Task.isCancelled, !openedInitialFile, failure == nil,
              let path = FileChangeSummary.relativePath(initialFilePath) else { return }
        let name = FileChangeSummary.filename(path)
        let entry = directory?.entries.first(where: { $0.path == path && !$0.isDirectory })
            ?? WorkspaceEntry(name: name, path: path, isDirectory: false, byteSize: nil,
                              mimeType: UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)?.preferredMIMEType)
        let captured = location
        if await loadWorkspaceFile(entry), isCurrent(captured) { openedInitialFile = true }
    }
    private func toggleHiddenFiles() {
        invalidateLocation()
        showHidden.toggle()
        Task { await loadDirectory(reset: true, preserveUntilLoaded: true) }
    }
    @discardableResult private func loadDirectory(reset: Bool, offset: Int = 0,
                                                   preserveUntilLoaded: Bool = false) async -> Bool {
        guard let root = selectedRoot, root.isDirectory else { return false }
        let captured = location
        let requestID = UUID()
        directoryRequestID = requestID
        if reset && !preserveUntilLoaded { directory = nil }
        let loadingID = beginLoading()
        defer { loadingRequests.remove(loadingID) }
        do {
            let page = try await model.loadWorkspaceDirectory(chat, root: root, path: captured.path,
                                                              showHidden: captured.hidden, offset: offset)
            guard isCurrent(captured), requestID == directoryRequestID else { return false }
            failure = nil
            missingDirectory = false
            if reset || directory == nil { directory = page }
            else if let current = directory { directory = WorkspaceDirectoryPage(rootId: page.rootId, path: page.path, parentPath: page.parentPath, entries: current.entries + page.entries, nextOffset: page.nextOffset) }
            return true
        } catch {
            guard isCurrent(captured), requestID == directoryRequestID else { return false }
            if case PairingFailure.response(404) = error, !captured.path.isEmpty {
                missingDirectory = true
                failure = "This folder moved or was deleted. Try again to return to the workspace root."
            } else { failure = workspaceBrowserError(error) }
            return false
        }
    }
    private func loadGit() async {
        guard let root = selectedRoot else { return }
        let captured = location
        let requestID = UUID()
        gitRequestID = requestID
        let loadingID = beginLoading()
        defer { loadingRequests.remove(loadingID) }
        do {
            let next = try await model.loadWorkspaceGitStatus(chat, root: root)
            guard isCurrent(captured), requestID == gitRequestID else { return }
            git = next; failure = nil
        } catch {
            guard isCurrent(captured), requestID == gitRequestID else { return }
            failure = workspaceBrowserError(error)
        }
    }
    private func open(_ entry: WorkspaceEntry) { if entry.isDirectory { navigate(to: entry.path) } else { Task { await loadWorkspaceFile(entry) } } }
    private func openRootFile(_ root: WorkspaceRoot) {
        let name = URL(fileURLWithPath: root.path).lastPathComponent
        let mime: String
        if let advertised = root.mimeType {
            mime = advertised
        } else if let inferred = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)?.preferredMIMEType {
            mime = inferred
        } else {
            mime = "application/octet-stream"
        }
        Task { await loadWorkspaceFile(WorkspaceEntry(name: name, path: "", isDirectory: false, byteSize: root.byteSize, mimeType: mime)) }
    }
    @discardableResult private func loadWorkspaceFile(_ entry: WorkspaceEntry) async -> Bool {
        guard let root = selectedRoot else { return false }
        let captured = location
        let requestID = UUID()
        fileRequestID = requestID
        let loadingID = beginLoading()
        failure = nil
        defer { loadingRequests.remove(loadingID) }
        do {
            if Self.isMedia(entry) {
                let loader = try model.workspaceMediaLoader(chat, root: root, entry: entry)
                guard isCurrent(captured), requestID == fileRequestID else { loader.cancelAll(); return false }
                mediaSelection = try WorkspaceMediaSelection(id: root.id + ":" + entry.path,
                                                              name: entry.name, loader: loader)
                return true
            }
            let data = try await model.downloadWorkspaceFile(chat, root: root, entry: entry)
            let sha256 = await Task.detached(priority: .userInitiated) { ConversationFile.digest(data) }.value
            guard isCurrent(captured), requestID == fileRequestID else { return false }
            let carriedNote: String
            if let reanchor, replacingAnnotationID != nil,
               reanchor.conversationId == chat.id,
               reanchor.projectId == model.projects.details[chat.id]?.projectId,
               reanchor.rootId == root.id, reanchor.path == entry.path {
                carriedNote = reanchor.note
            } else { carriedNote = "" }
            textAnnotationDraft.reset(note: carriedNote)
            modelSession?.close()
            modelSession = WorkspaceModelPreview.supports(entry.name) ? WorkspaceModelPreviewSession() : nil
            pdfSession = PDFPreviewSession()
            previewRevision = WorkspaceRevisionState(data: data, sha256: sha256)
            if PhotoViewerRouting.isImage(mimeType: entry.mimeType) { selection = WorkspacePreviewSelection(id: root.id + ":" + entry.path, name: entry.name, mimeType: entry.mimeType ?? "image/*", data: data, sha256: sha256, rootID: root.id, path: entry.path, scope: captured.scope) }
            else { attachmentSelection = nil; attachmentData = nil; attachmentDigest = nil; selection = nil; selectedDiff = nil; diffText = nil; documentSelection = WorkspacePreviewSelection(id: root.id + ":" + entry.path, name: entry.name, mimeType: entry.mimeType ?? "application/octet-stream", data: data, sha256: sha256, rootID: root.id, path: entry.path, scope: captured.scope) }
            return true
        } catch {
            guard isCurrent(captured), requestID == fileRequestID else { return false }
            failure = "This file could not be opened. It may have moved, been deleted, or need workspace access."
            return false
        }
    }
    private static func isMedia(_ entry: WorkspaceEntry) -> Bool {
        guard let ext = entry.name.split(separator: ".").last?.lowercased() else { return false }
        return ["mp4", "mov", "m4a", "mp3", "wav"].contains(ext)
    }
    private func annotationContext(for item: WorkspacePreviewSelection) -> ArtifactPreviewContext? {
        guard let rootID = item.rootID, let path = item.path, !path.isEmpty,
              let scope = item.scope, scope == model.assignmentScope,
              let projectID = model.projects.details[chat.id]?.projectId,
              model.canAnnotate(chat, replacing: reanchorDraft(for: item)?.id) else { return nil }
        return ArtifactPreviewContext(projectID: projectID, conversationID: chat.id,
                                      rootID: rootID, path: path, scope: scope)
    }
    private func reanchorDraft(for item: WorkspacePreviewSelection) -> (id: String, note: String)? {
        guard let reanchor, let replacingAnnotationID,
              reanchor.conversationId == chat.id,
              reanchor.projectId == model.projects.details[chat.id]?.projectId,
              reanchor.rootId == item.rootID, reanchor.path == item.path else { return nil }
        return (replacingAnnotationID, reanchor.note)
    }
    private func revisionRefresh(for item: WorkspacePreviewSelection) -> (() async throws -> Data)? {
        guard let rootID = item.rootID, let path = item.path,
              let scope = item.scope, scope == model.assignmentScope,
              let root = response?.roots.first(where: { $0.id == rootID }) else { return nil }
        let entry = WorkspaceEntry(name: item.name, path: path, isDirectory: false,
                                   byteSize: nil, mimeType: item.mimeType)
        return {
            guard scope == model.assignmentScope, !model.accessEnded else { throw CancellationError() }
            let data = try await model.refreshWorkspaceFile(chat, root: root, entry: entry)
            guard scope == model.assignmentScope, !model.accessEnded else { throw CancellationError() }
            return data
        }
    }
    private func revisionNotice(for item: WorkspacePreviewSelection) -> ((String) async -> Void)? {
        guard let rootID = item.rootID, let path = item.path, let scope = item.scope else { return nil }
        return { sha256 in
            guard scope == model.assignmentScope else { return }
            await model.noteWorkspaceRevision(chat, rootID: rootID, path: path, currentSha256: sha256)
        }
    }
    private func openAttachment(_ file: ConversationFile) {
        if PhotoViewerRouting.isImage(file) { attachmentPhoto = file }
        else { Task { await loadAttachment(file) } }
    }
    private func loadAttachment(_ file: ConversationFile) async {
        let captured = location
        let requestID = UUID()
        attachmentRequestID = requestID
        let loadingID = beginLoading()
        failure = nil
        defer { loadingRequests.remove(loadingID) }
        do {
            let data = try await model.download(file, chat: chat)
            let digest = await Task.detached(priority: .userInitiated) { ConversationFile.digest(data) }.value
            guard isCurrent(captured), requestID == attachmentRequestID,
                  visibleAttachments.contains(where: { $0.id == file.id }) else { return }
            textAnnotationDraft.reset()
            modelSession?.close()
            modelSession = WorkspaceModelPreview.supports(file.name) ? WorkspaceModelPreviewSession() : nil
            pdfSession = PDFPreviewSession()
            previewRevision = WorkspaceRevisionState(data: data, sha256: digest)
            attachmentSelection = file; attachmentData = data; attachmentDigest = digest
        }
        catch {
            guard isCurrent(captured), requestID == attachmentRequestID else { return }
            failure = workspaceBrowserError(error)
        }
    }
    private func openDiff(_ change: WorkspaceGitChange) {
        let staged = change.indexStatus != " " && change.indexStatus != "?"
        let unstaged = change.worktreeStatus != " " || change.indexStatus == "?"
        if staged && unstaged { diffChoice = change } else { loadDiff(change, staged: staged) }
    }
    private func loadDiff(_ change: WorkspaceGitChange, staged: Bool) {
        guard let root = selectedRoot else { return }
        let captured = location
        let requestID = UUID()
        diffRequestID = requestID
        selectedDiff = change
        diffText = nil
        Task {
            do {
                let response = try await model.loadWorkspaceGitDiff(chat, root: root, path: change.path, staged: staged)
                guard isCurrent(captured), requestID == diffRequestID,
                      selectedDiff?.id == change.id else { return }
                diffText = response.diff
            } catch {
                guard isCurrent(captured), requestID == diffRequestID,
                      selectedDiff?.id == change.id else { return }
                failure = workspaceBrowserError(error)
                selectedDiff = nil
            }
        }
    }
    private func workspaceBrowserError(_ error: Error) -> String {
        if case PairingFailure.response(let code) = error {
            switch code {
            case 403: return "Access to this folder changed. Review the Project's folders on your Mac, then try again."
            case 404: return "This conversation or Project folder is unavailable. Check it on your Mac, or update Wonder there if Files is missing."
            case 409: return "These files changed while you were browsing. Close Files, then open it again."
            case 501: return "Update Wonder on your Mac to browse these files."
            case 503: return "Your Mac couldn't verify this folder. Check the connection, then try again."
            default: break
            }
        }
        return "Files could not be loaded. Check your Mac and try again."
    }
}

private struct WorkspaceMediaPreview: View {
    @ObservedObject var selection: WorkspaceMediaSelection
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let failure = selection.failure {
                    ContentUnavailableView("Playback unavailable", systemImage: "play.slash",
                                           description: Text(failure))
                        .accessibilityIdentifier("workspace-media-unavailable")
                } else if let player = selection.player {
                    VideoPlayer(player: player)
                        .accessibilityIdentifier("workspace-media-player")
                } else {
                    ProgressView("Loading media…")
                        .accessibilityIdentifier("workspace-media-loading")
                }
            }
            .navigationTitle(selection.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(onClose == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if onClose == nil {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("workspace-media-close")
                }
            }
            .onAppear { selection.start() }
        }
    }
}

private struct WorkspaceRootMenuButton: View {
    let root: WorkspaceRoot
    let action: (WorkspaceRoot) -> Void

    var body: some View {
        Button(root.label) { action(root) }
            .accessibilityIdentifier("workspace-root:\(root.id)")
    }
}

private struct WorkspaceBrowserDoneButton: View {
    let action: () -> Void

    var body: some View {
        Button("Done", action: action)
            .accessibilityIdentifier("workspace-close")
    }
}

private struct WorkspaceImagePreview: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let item: WorkspacePreviewSelection
    let context: ArtifactPreviewContext
    let refresh: (() async throws -> Data)?
    let onRevision: ((String) async -> Void)?
    let refreshSequence: UInt64?
    let initialNote: String
    let onClose: () -> Void
    let onAnnotation: (ArtifactAnnotation) throws -> Void
    @ObservedObject var revision: WorkspaceRevisionState
    @State private var showingRegion = false

    init(model: ConnectionModel, chat: ChatSummary, item: WorkspacePreviewSelection,
         context: ArtifactPreviewContext, revision: WorkspaceRevisionState,
         refresh: (() async throws -> Data)?,
         onRevision: ((String) async -> Void)?, refreshSequence: UInt64?,
         initialNote: String, onClose: @escaping () -> Void,
         onAnnotation: @escaping (ArtifactAnnotation) throws -> Void) {
        self.model = model; self.chat = chat; self.item = item; self.context = context
        self.revision = revision
        self.refresh = refresh; self.onRevision = onRevision; self.refreshSequence = refreshSequence
        self.initialNote = initialNote
        self.onClose = onClose
        self.onAnnotation = onAnnotation
    }

    var body: some View {
        PhotoViewer(model: model, chat: chat, name: item.name, mimeType: item.mimeType,
                    sourceID: item.id, localData: revision.currentData, file: nil, revision: revision.currentSha256,
                    onClose: onClose, showsHeader: false)
            .overlay(alignment: .top) {
                if refresh != nil {
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Check for changes", systemImage: "arrow.clockwise") {
                            revision.manualRefreshTask?.cancel()
                            revision.manualRefreshTask = Task { await checkForRevision() }
                        }
                            .disabled(revision.refreshing)
                            .accessibilityIdentifier("workspace-image-refresh")
                        if revision.offeredData != nil {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("New image version available. Preview notes on the old version need a new selection.")
                                    .accessibilityIdentifier("workspace-image-revision-warning")
                                Button("Show new version") {
                                    revision.showOfferedRevision()
                                }
                                .accessibilityIdentifier("workspace-image-show-revision")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(Color.orange.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
                        } else if let refreshFailure = revision.refreshFailure {
                            Text(refreshFailure).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("workspace-image-refresh-error")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.footnote).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.top, 8)
                }
            }
            .overlay(alignment: .bottom) {
                Button("Annotate region", systemImage: "square.dashed") { showingRegion = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 18)
                    .accessibilityIdentifier("annotation-image-open")
            }
            .fullScreenCover(isPresented: $showingRegion) {
                WorkspaceRegionEditor(name: item.name, source: revision.currentData, context: context,
                                      format: .image, onAnnotation: onAnnotation, initialNote: initialNote)
            }
            .task(id: refreshSequence) {
                guard let refreshSequence else { return }
                await revision.observe(sequence: refreshSequence, refresh: refresh, onRevision: onRevision,
                    failureMessage: "Could not check this image. Check your Mac or workspace access and try again.")
            }
    }

    private func checkForRevision() async {
        await revision.checkForRevision(refresh: refresh, onRevision: onRevision,
            failureMessage: "Could not check this image. Check your Mac or workspace access and try again.")
    }
}

private enum WorkspaceRegionFormat: Sendable { case image, pdf }

private struct WorkspaceRegionEditor: View {
    let name: String
    let source: Data
    let context: ArtifactPreviewContext
    let format: WorkspaceRegionFormat
    let onAnnotation: (ArtifactAnnotation) throws -> Void
    var initialNote: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var page = 1
    @State private var pageCount = 0
    @State private var preview: UIImage?
    @State private var region: CGRect?
    @State private var note = ""
    @State private var failure: String?
    @State private var loading = true
    @State private var showingAreaControls = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if format == .pdf, pageCount > 0 {
                    HStack {
                        Button("Previous page", systemImage: "chevron.left") {
                            guard !loading else { return }
                            loading = true
                            page -= 1
                        }
                            .disabled(loading || page <= 1).accessibilityIdentifier("annotation-previous-page")
                        Spacer()
                        Text("Page \(page) of \(pageCount)").accessibilityIdentifier("annotation-page-position")
                        Spacer()
                        Button("Next page", systemImage: "chevron.right") {
                            guard !loading else { return }
                            loading = true
                            page += 1
                        }
                            .disabled(loading || page >= pageCount).accessibilityIdentifier("annotation-next-page")
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                if loading { ProgressView("Preparing preview…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let preview {
                    WorkspaceRegionCanvas(image: preview, region: $region)
                    Text(regionSummary)
                        .font(.footnote).foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("annotation-region-status")
                } else {
                    ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text("This file could not be prepared for annotation."))
                }
            }
            .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Button(format == .pdf ? "Select whole page" : "Select whole image") {
                        region = CGRect(x: 0, y: 0, width: 1, height: 1)
                    }
                    .disabled(loading || preview == nil)
                    .accessibilityIdentifier("annotation-region-all")
                    DisclosureGroup("Adjust selected area", isExpanded: $showingAreaControls) {
                        Slider(value: regionValue(\.minX), in: 0...0.99, step: 0.01) { Text("Left") }
                        Slider(value: regionValue(\.minY), in: 0...0.99, step: 0.01) { Text("Top") }
                        Slider(value: regionValue(\.width), in: 0.01...1, step: 0.01) { Text("Width") }
                        Slider(value: regionValue(\.height), in: 0.01...1, step: 0.01) { Text("Height") }
                    }
                    .disabled(loading || preview == nil)
                    .onChange(of: showingAreaControls) { _, expanded in
                        if expanded && region == nil { region = CGRect(x: 0, y: 0, width: 1, height: 1) }
                    }
                    .accessibilityIdentifier("annotation-region-adjust")
                    TextField("What should the agent notice?", text: $note, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("annotation-region-note")
                    if note.utf8.count > 4096 { Text("Keep the note under 4,096 bytes.").font(.footnote).foregroundStyle(.red) }
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("annotation-region-error") }
                    Button("Add to message") { addAnnotation() }
                        .buttonStyle(.borderedProminent)
                        .disabled(loading || region == nil || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.utf8.count > 4096)
                        .accessibilityIdentifier("annotation-region-add")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.regularMaterial)
            }
            .task(id: page) { await preparePreview() }
            .onAppear { if note.isEmpty { note = initialNote } }
        }
    }

    private func preparePreview() async {
        preview = nil; region = nil; showingAreaControls = false; loading = true; failure = nil
        let source = source
        let page = page
        let format = format
        let rendering = Task.detached(priority: .userInitiated) { () -> (UIImage?, Int) in
            switch format {
            case .image:
                return (ToolPreviewImage.decode(source), 1)
            case .pdf:
                guard let document = PDFDocument(data: source), document.pageCount > 0,
                      page <= min(document.pageCount, 10_000), let pdfPage = document.page(at: page - 1) else { return (nil, 0) }
                return (pdfPage.thumbnail(of: CGSize(width: 1200, height: 1600), for: .cropBox), min(document.pageCount, 10_000))
            }
        }
        let result = await withTaskCancellationHandler(operation: { await rendering.value }, onCancel: { rendering.cancel() })
        guard !Task.isCancelled else { return }
        preview = result.0
        pageCount = result.1
        loading = false
        if result.0 == nil { failure = "The selected page could not be rendered." }
    }

    private func addAnnotation() {
        guard !loading, let region else { return }
        do {
            let x = Double(region.minX), y = Double(region.minY)
            let width = Double(region.width), height = Double(region.height)
            let annotation: ArtifactAnnotation
            switch format {
            case .image:
                annotation = try ArtifactAnnotation(projectId: context.projectID, conversationId: context.conversationID,
                    rootId: context.rootID, path: context.path, source: source,
                    imageX: x, y: y, width: width, height: height, note: note)
            case .pdf:
                annotation = try ArtifactAnnotation(projectId: context.projectID, conversationId: context.conversationID,
                    rootId: context.rootID, path: context.path, source: source,
                    pdfPage: page, x: x, y: y, width: width, height: height, note: note)
            }
            try onAnnotation(annotation)
            dismiss()
        } catch { failure = "The preview note could not be saved. Reopen the file and try again." }
    }

    private var regionSummary: String {
        guard let region else { return "Drag on the preview to select an area." }
        let x = Int((region.minX * 100).rounded()), y = Int((region.minY * 100).rounded())
        let width = Int((region.width * 100).rounded()), height = Int((region.height * 100).rounded())
        return "Selected area: \(x)% from left, \(y)% from top; \(width)% wide, \(height)% high."
    }

    private func regionValue(_ key: KeyPath<CGRect, CGFloat>) -> Binding<Double> {
        Binding(get: { Double((region ?? CGRect(x: 0, y: 0, width: 1, height: 1))[keyPath: key]) }, set: { value in
            var current = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            if key == \.minX { current.origin.x = CGFloat(min(0.99, max(0, value))) }
            else if key == \.minY { current.origin.y = CGFloat(min(0.99, max(0, value))) }
            else if key == \.width { current.size.width = CGFloat(min(1, max(0.01, value))) }
            else { current.size.height = CGFloat(min(1, max(0.01, value))) }
            current.size.width = min(current.width, 1 - current.minX)
            current.size.height = min(current.height, 1 - current.minY)
            region = current
        })
    }
}

private struct WorkspaceRegionCanvas: View {
    let image: UIImage
    @Binding var region: CGRect?
    @State private var dragOrigin: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let fit = fittedRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                Color(uiColor: .secondarySystemBackground)
                Image(uiImage: image)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .accessibilityLabel("Preview page or image")
                    .accessibilityIdentifier("annotation-preview-image")
                if let region {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.18))
                        .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) }
                        .frame(width: fit.width * region.width, height: fit.height * region.height)
                        .offset(x: fit.minX + fit.width * region.minX,
                                y: fit.minY + fit.height * region.minY)
                        .accessibilityHidden(true)
                }
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let point = normalized(value.location, in: fit)
                            if dragOrigin == nil { dragOrigin = point }
                            if let dragOrigin { region = selection(from: dragOrigin, to: point) }
                        }
                        .onEnded { value in
                            let point = normalized(value.location, in: fit)
                            if let dragOrigin { region = selection(from: dragOrigin, to: point) }
                            dragOrigin = nil
                        })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Preview region selection")
                    .accessibilityHint("Drag across the image to select an area, or use Select whole image or page.")
                    .accessibilityIdentifier("annotation-region-canvas")
            }
            .clipped()
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        guard image.size.width > 0, image.size.height > 0, size.width > 0, size.height > 0 else { return .zero }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let width = image.size.width * scale, height = image.size.height * scale
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: min(1, max(0, point.x / rect.width)), y: min(1, max(0, point.y / rect.height)))
    }
    private func selection(from start: CGPoint, to end: CGPoint) -> CGRect? {
        let x = min(start.x, end.x), y = min(start.y, end.y)
        let width = min(abs(end.x - start.x), 1 - x), height = min(abs(end.y - start.y), 1 - y)
        guard width > 0.005, height > 0.005 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Native selection preserves the exact highlighted characters, including
/// Unicode and line endings, for a revision-bound preview comment.
private struct SelectablePreviewText: UIViewRepresentable {
    let text: String
    @Binding var selectedRange: NSRange?
    let selectionResetID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(selectedRange: $selectedRange, selectionResetID: selectionResetID)
    }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        context.coordinator.isUpdating = true
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.backgroundColor = .clear
        view.textColor = .label
        view.tintColor = .tintColor
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        view.text = text
        if let selectedRange { view.selectedRange = selectedRange }
        if let selectedRange, selectedRange.length > 0,
           NSMaxRange(selectedRange) <= view.textStorage.length {
            view.textStorage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35),
                                          range: selectedRange)
            context.coordinator.highlightedRange = selectedRange
        }
        context.coordinator.isUpdating = false
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.selectedRange = $selectedRange
        let reset = context.coordinator.selectionResetID != selectionResetID
        if reset {
            context.coordinator.selectionResetID = selectionResetID
            context.coordinator.pendingSelection = nil
            context.coordinator.selectionEventID = UUID()
        }
        context.coordinator.isUpdating = true
        // The view is recreated for each source SHA; text is immutable within
        // that identity. Do not compare or assign 128 KB on every note keystroke.
        if reset || (selectedRange == nil && context.coordinator.pendingSelection == nil) {
            if view.selectedRange.length > 0 {
                view.selectedRange = NSRange(location: view.selectedRange.location, length: 0)
            }
        } else if let selectedRange, context.coordinator.pendingSelection == nil,
                  view.selectedRange != selectedRange {
            view.selectedRange = selectedRange
        }
        let highlightedRange = selectedRange.flatMap { range in
            range.length > 0 && NSMaxRange(range) <= view.textStorage.length ? range : nil
        }
        if context.coordinator.highlightedRange != highlightedRange {
            if let previous = context.coordinator.highlightedRange {
                view.textStorage.removeAttribute(.backgroundColor, range: previous)
            }
            if let highlightedRange {
                view.textStorage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35),
                                              range: highlightedRange)
            }
            context.coordinator.highlightedRange = highlightedRange
        }
        context.coordinator.isUpdating = false
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var selectedRange: Binding<NSRange?>
        var selectionResetID: UUID
        var selectionEventID = UUID()
        var pendingSelection: NSRange?
        var highlightedRange: NSRange?
        var isUpdating = false
        init(selectedRange: Binding<NSRange?>, selectionResetID: UUID) {
            self.selectedRange = selectedRange
            self.selectionResetID = selectionResetID
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            let range = textView.selectedRange
            let selected = range.length > 0 ? range : nil
            pendingSelection = selected
            let eventID = UUID()
            selectionEventID = eventID
            Task { @MainActor [weak self] in
                guard let self, self.selectionEventID == eventID else { return }
                self.pendingSelection = nil
                if self.selectedRange.wrappedValue != selected {
                    self.selectedRange.wrappedValue = selected
                }
            }
        }
    }
}

private struct WorkspaceDocumentPreview: View {
    let name: String
    let mimeType: String
    let pdfSession: PDFPreviewSession?
    let annotationContext: ArtifactPreviewContext?
    let onAnnotation: ((ArtifactAnnotation) throws -> Void)?
    let refresh: (() async throws -> Data)?
    let onRevision: ((String) async -> Void)?
    let refreshSequence: UInt64?
    let onClose: (() -> Void)?
    @ObservedObject var revision: WorkspaceRevisionState
    @ObservedObject var draft: WorkspaceTextAnnotationDraft
    init(name: String, mimeType: String, revision: WorkspaceRevisionState,
         draft: WorkspaceTextAnnotationDraft,
         pdfSession: PDFPreviewSession? = nil,
         annotationContext: ArtifactPreviewContext? = nil,
         onAnnotation: ((ArtifactAnnotation) throws -> Void)? = nil,
         refresh: (() async throws -> Data)? = nil,
         onRevision: ((String) async -> Void)? = nil,
         refreshSequence: UInt64? = nil,
         onClose: (() -> Void)? = nil) {
        self.name = name; self.mimeType = mimeType; self.pdfSession = pdfSession
        self.revision = revision
        self.draft = draft
        self.annotationContext = annotationContext; self.onAnnotation = onAnnotation
        self.refresh = refresh; self.onRevision = onRevision; self.refreshSequence = refreshSequence
        self.onClose = onClose
    }
    @Environment(\.dismiss) private var dismiss
    @State private var showingPDFRegion = false
    var body: some View {
        NavigationStack {
            Group {
                if mimeType == "application/pdf" {
                    PDFPreview(data: revision.currentData, revision: revision.currentSha256,
                               session: pdfSession)
                        .ignoresSafeArea(edges: .bottom)
                        .accessibilityIdentifier("workspace-pdf-preview")
                }
                else if revision.preparingText && revision.preparedText == nil { ProgressView("Preparing preview…") }
                else if mimeType == "text/html", let html = revision.preparedText { ConstrainedHTML(html: html) }
                else if let text = revision.preparedText, canAnnotate {
                    SelectablePreviewText(text: text, selectedRange: $draft.selectedRange,
                                          selectionResetID: draft.selectionResetID)
                        .id(revision.currentSha256)
                        .accessibilityIdentifier("annotation-selectable-text")
                } else if let text = revision.preparedText {
                    ScrollView {
                        Text(text).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }
                }
                else {
                    ContentUnavailableView("Preview unavailable", systemImage: "doc",
                        description: Text(revision.previewTruncated
                            ? "This HTML file is too large to preview safely. Open it on your Mac."
                            : "This file type does not have a preview in Wonder."))
                }
            }
            .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .toolbar(onClose == nil ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if onClose == nil {
                    ToolbarItem(placement: .topBarLeading) {
                        if mimeType == "application/pdf", annotationContext != nil, onAnnotation != nil {
                            Button("Annotate region") { showingPDFRegion = true }
                                .accessibilityIdentifier("annotation-pdf-open")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("workspace-document-close")
                    }
                    if refresh != nil {
                        ToolbarItem(placement: .topBarTrailing) { refreshButton }
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if revision.previewTruncated, revision.preparedText != nil {
                    Text("Showing the first 128 KB. Open the file on your Mac to read the rest.")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .accessibilityIdentifier("workspace-document-truncated")
                }
                if onClose != nil && (refresh != nil || mimeType == "application/pdf" && annotationContext != nil && onAnnotation != nil) {
                    HStack {
                        if mimeType == "application/pdf", annotationContext != nil, onAnnotation != nil {
                            Button("Annotate region") { showingPDFRegion = true }
                                .accessibilityIdentifier("annotation-pdf-open")
                        }
                        Spacer()
                        if refresh != nil { refreshButton }
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                }
                if revision.offeredData != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New file version available. Preview notes on the old version need a new selection.")
                            .font(.footnote)
                            .accessibilityIdentifier("workspace-document-revision-warning")
                        Button("Show new version") { showOfferedRevision() }
                            .accessibilityIdentifier("workspace-document-show-revision")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Color.orange.opacity(0.16))
                } else if let refreshFailure = revision.refreshFailure {
                    Text(refreshFailure).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .accessibilityIdentifier("workspace-document-refresh-error")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if canAnnotate, let selectedTextRange = draft.selectedRange, selectedTextRange.length > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(selectedExcerpt(for: selectedTextRange))
                                .font(.footnote).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("annotation-selected-text")
                            Button("Cancel comment", systemImage: "xmark") {
                                draft.clearSelection(discardNote: true)
                            }
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("annotation-cancel")
                            if draft.editingSelection {
                                Button("Save comment", systemImage: "checkmark") { addAnnotation() }
                                    .labelStyle(.iconOnly)
                                    .frame(minWidth: 44, minHeight: 44)
                                    .disabled(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.note.utf8.count > 4096)
                                    .accessibilityIdentifier("annotation-add")
                            } else {
                                Button("Comment", systemImage: "text.bubble") { draft.editingSelection = true }
                                    .frame(minHeight: 44)
                                    .accessibilityIdentifier("annotation-comment")
                            }
                        }
                        if draft.editingSelection {
                            TextField("Add a comment", text: $draft.note, axis: .vertical)
                                .lineLimit(2...4)
                                .accessibilityIdentifier("annotation-note")
                        }
                        if draft.note.utf8.count > 4096 { Text("Keep the comment under 4,096 bytes.").font(.footnote).foregroundStyle(.red) }
                        if let error = draft.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: 600, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12).padding(.bottom, 4)
                }
            }
            .fullScreenCover(isPresented: $showingPDFRegion) {
                if let annotationContext, let onAnnotation {
                    WorkspaceRegionEditor(name: name, source: revision.currentData, context: annotationContext,
                                          format: .pdf, onAnnotation: onAnnotation, initialNote: draft.note)
                }
            }
            .task(id: refreshSequence) {
                guard let refreshSequence else { return }
                await revision.observe(sequence: refreshSequence, refresh: refresh, onRevision: onRevision,
                    failureMessage: "Could not check this file. Check your Mac or workspace access and try again.")
            }
            .task(id: revision.currentSha256) { await revision.prepareTextIfNeeded(mimeType: mimeType) }
        }
    }

    private var canAnnotate: Bool {
        !revision.preparingText && annotationContext != nil && onAnnotation != nil && mimeType != "text/html" &&
        (mimeType.hasPrefix("text/") || ["application/json", "application/yaml", "application/xml", "application/sql"].contains(mimeType)) &&
        revision.preparedText != nil
    }
    private var refreshButton: some View {
        Button("Check for changes", systemImage: "arrow.clockwise") {
            revision.manualRefreshTask?.cancel()
            revision.manualRefreshTask = Task { await checkForRevision() }
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 44, minHeight: 44)
        .disabled(revision.refreshing)
        .accessibilityIdentifier("workspace-document-refresh")
    }
    private func selectedExcerpt(for range: NSRange) -> String {
        guard let text = revision.preparedText, NSMaxRange(range) <= (text as NSString).length else { return "Selected text" }
        let selected = (text as NSString).substring(with: range)
        return String(selected.prefix(120)).replacingOccurrences(of: "\n", with: " ")
    }
    private func addAnnotation() {
        guard let annotationContext, let onAnnotation, let selectedTextRange = draft.selectedRange,
              let text = revision.preparedText, let range = Range(selectedTextRange, in: text) else { return }
        do {
            let start = text[..<range.lowerBound].utf8.count
            let end = start + text[range].utf8.count
            let annotation = try ArtifactAnnotation(projectId: annotationContext.projectID,
                conversationId: annotationContext.conversationID, rootId: annotationContext.rootID,
                path: annotationContext.path, source: revision.currentData, mimeType: mimeType,
                startByte: start, endByte: end, note: draft.note)
            try onAnnotation(annotation)
            draft.clearSelection(discardNote: true)
        } catch { draft.error = "The preview note could not be saved. Reopen the file and try again." }
    }

    private func checkForRevision() async {
        await revision.checkForRevision(refresh: refresh, onRevision: onRevision,
            failureMessage: "Could not check this file. Check your Mac or workspace access and try again.")
    }

    private func showOfferedRevision() {
        // Clear the old text before the replacement is decoded so its visible
        // content cannot be mistaken for the newly selected revision.
        revision.showOfferedRevision()
        draft.clearSelection(discardNote: false)
    }
}

private struct ArtifactNoteEditor: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let attachment: ComposerAttachment
    let expectedScope: String
    let onReanchor: (ArtifactAnnotation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var annotation: ArtifactAnnotation?
    @State private var note = ""
    @State private var failure: String?
    @State private var loading = true

    init(model: ConnectionModel, chat: ChatSummary, attachment: ComposerAttachment,
         onReanchor: @escaping (ArtifactAnnotation) -> Void) {
        self.model = model; self.chat = chat; self.attachment = attachment
        self.onReanchor = onReanchor
        expectedScope = model.assignmentScope
    }

    var body: some View {
        NavigationStack {
            Form {
                if loading { ProgressView("Opening preview note…") }
                else if let annotation {
                    Section("Selected preview") {
                        Text(annotation.path).lineLimit(2)
                        Text(anchorDescription(annotation.anchor)).foregroundStyle(.secondary)
                        if model.isAnnotationStale(attachment.id, chat: chat.id) {
                            Text("The source changed. This selection belongs to an older version; choose a new area or lines before sending.")
                                .foregroundStyle(.orange)
                                .accessibilityIdentifier("annotation-edit-stale")
                        }
                        Button("Choose a new selection in Files") {
                            onReanchor(annotation)
                            dismiss()
                        }
                        .accessibilityIdentifier("annotation-edit-reanchor")
                    }
                    Section("Note for the agent") {
                        TextEditor(text: $note)
                            .frame(minHeight: 110)
                            .accessibilityIdentifier("annotation-edit-note")
                        if note.utf8.count > 4096 { Text("Keep the note under 4,096 bytes.").foregroundStyle(.red) }
                    }
                }
                if let failure { Text(failure).foregroundStyle(.red).accessibilityIdentifier("annotation-edit-error") }
            }
            .navigationTitle("Preview note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(annotation == nil || note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.utf8.count > 4096)
                        .accessibilityIdentifier("annotation-edit-save")
                }
            }
            .task(id: attachment.id) { await load() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let data: Data
            if let local = attachment.data { data = local }
            else if let remote = attachment.remoteFile { data = try await model.download(remote, chat: chat) }
            else { throw FileFailure.notUploaded }
            guard !Task.isCancelled, !model.accessEnded,
                  expectedScope == model.assignmentScope else { throw FileFailure.integrity }
            let value = try ArtifactAnnotation.read(data)
            guard value.conversationId == chat.id,
                  value.projectId == model.projects.details[chat.id]?.projectId else { throw FileFailure.integrity }
            annotation = value
            note = value.note
        } catch { failure = "This preview note could not be opened. Reopen Files to create a new one." }
    }
    private func save() {
        guard let annotation else { return }
        do {
            try model.stageAnnotation(annotation.replacingNote(note), chat: chat,
                                      expectedScope: expectedScope, replacing: attachment.id,
                                      preserveStaleOnReplace: true)
            dismiss()
        } catch { failure = "This preview note could not be saved. Reopen Files to create a new one." }
    }
    private func anchorDescription(_ anchor: ArtifactAnnotation.Anchor) -> String {
        switch anchor {
        case .textLines(let start, let end): "Lines \(start)–\(end)"
        case .textRange: "Highlighted text"
        case .imageRegion: "Selected image area"
        case .pdfRegion(let page, _, _, _, _): "Selected area on page \(page)"
        }
    }
}

struct WorkspaceDiffPreview: View {
    let path: String
    let state: String
    let diff: String
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { Text(diff.isEmpty ? "No textual diff is available for this change." : diff).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding().accessibilityIdentifier("workspace-diff-text") }
                .navigationTitle(path).navigationBarTitleDisplayMode(.inline)
                .toolbar(onClose == nil ? .visible : .hidden, for: .navigationBar)
                .toolbar {
                    if onClose == nil {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                                .accessibilityIdentifier("workspace-diff-close")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) { Text(state.capitalized).font(.caption).foregroundStyle(.secondary).padding(.bottom, 8) }
        }
    }
}

struct PreviewDeck: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    var initialFile: ConversationFile? = nil
    var attachmentIDs: [String]? = nil
    private var listedFiles: [ConversationFile] {
        (model.files[chat.id] ?? []).filter { attachmentIDs?.contains($0.id) ?? true }
    }
    @Environment(\.dismiss) private var dismiss
    @State private var selected: ConversationFile?
    @State private var bytes: Data?
    @State private var exporting = false
    @State private var busy = false
    @State private var failure: String?
    @State private var photoFile: ConversationFile?
    var body: some View {
        NavigationStack {
            Group {
                if busy { ProgressView("Loading verified file…") }
                else if let selected, let bytes, !PhotoViewerRouting.isImage(selected) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if selected.mimeType == "application/pdf" { PDFPreview(data: bytes, revision: selected.sha256).frame(minHeight: 550) }
                            else if selected.mimeType == "text/html", let html = String(data: bytes, encoding: .utf8) { ConstrainedHTML(html: html).frame(minHeight: 550) }
                            else if selected.mimeType?.hasPrefix("text/") == true, let text = String(data: bytes, encoding: .utf8) { Text(text).textSelection(.enabled) }
                            else { ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text("This file type does not have a preview in Wonder.")) }
                            Button("Save a copy", systemImage: "square.and.arrow.up") { exporting = true }.frame(minHeight: 44)
                            DisclosureGroup("Details") {
                                Text("Verified download · \(selected.updatedAt)").font(.caption)
                                Text(selected.sha256 ?? "").font(.caption.monospaced()).textSelection(.enabled)
                                Text(ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file)).font(.caption)
                            }
                        }.padding()
                    }
                } else {
                    List(listedFiles) { file in
                        Button {
                            if PhotoViewerRouting.isImage(file) { photoFile = file }
                            else { open(file) }
                        } label: {
                            Label(file.name, systemImage: PhotoViewerRouting.isImage(file) ? "photo" : "doc")
                        }
                        .disabled(!PhotoViewerRouting.isImage(file) && file.state != "available")
                        .accessibilityIdentifier("file-preview:\(file.id)")
                    }.overlay { if listedFiles.isEmpty { ContentUnavailableView(attachmentIDs == nil ? "No files yet" : "Attachments unavailable", systemImage: "doc", description: attachmentIDs == nil ? nil : Text("These attachments could not be found on your Mac.")) } }
                }
            }
            .safeAreaInset(edge: .bottom) { if let failure { VStack { FailureDetails(message: failure); Button("Try again") { if let selected { open(selected) } else { refresh() } } }.padding() } }
            .fileExporter(isPresented: $exporting, document: ExportedFile(data: bytes ?? Data()), contentType: selected?.mimeType.flatMap { UTType(mimeType: $0) } ?? .data, defaultFilename: selected?.name) { result in
                if case .failure = result { failure = "The copy could not be saved. Try another location." }
            }
            .navigationTitle(selected?.name ?? (attachmentIDs == nil ? "Files" : "Attachments"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(selected == nil ? "Done" : "Files") { if selected == nil { dismiss() } else { selected = nil; bytes = nil } }.disabled(busy) }
            }
            .fullScreenCover(item: $photoFile) { file in
                PhotoViewer(
                    model: model,
                    chat: chat,
                    file: file,
                    galleryFiles: ConversationAttachmentGallery.imageFiles(listedFiles),
                    initialFileID: file.id
                )
            }
            .task {
                if let initialFile {
                    if PhotoViewerRouting.isImage(initialFile) { photoFile = initialFile }
                    else { open(initialFile) }
                    return
                }
                refresh()
                if model.previewMode, let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-preview-document"), index + 1 < ProcessInfo.processInfo.arguments.count,
                   let file = model.files[chat.id]?.first(where: { $0.name == ProcessInfo.processInfo.arguments[index + 1] }) {
                    if PhotoViewerRouting.isImage(file) { photoFile = file }
                    else { open(file) }
                }
            }
        }
    }
    private func refresh() {
        busy = true; failure = nil
        Task { defer { busy = false }; do { try await model.loadFiles(chat) } catch { failure = "Files could not be loaded. Check your Mac and try again." } }
    }
    private func open(_ file: ConversationFile) {
        selected = file; bytes = nil; failure = nil; busy = true
        Task { defer { busy = false }; do { bytes = try await model.download(file, chat: chat) } catch { failure = "This file could not be verified or downloaded. Check your Mac and try again." } }
    }
}
/// A selected PDF retains its parsed document and viewport while SwiftUI
/// replaces the inline PDFView with a full-screen PDFView or vice versa.
@MainActor final class PDFPreviewSession {
    private struct Viewport {
        let pageIndex: Int
        let point: CGPoint?
        let scale: CGFloat
    }
    private(set) var document: PDFDocument?
    private(set) var revision: String?
    weak var activeView: PDFView?
    private var viewport: Viewport?

    func capture() {
        guard let view = activeView, let document = view.document,
              let page = view.currentDestination?.page ?? view.currentPage else { return }
        let destination = view.currentDestination
        let bounds = page.bounds(for: view.displayBox)
        let point: CGPoint?
        if let destination, bounds.width > 0, bounds.height > 0 {
            point = CGPoint(x: (destination.point.x - bounds.minX) / bounds.width,
                            y: (destination.point.y - bounds.minY) / bounds.height)
        } else { point = nil }
        viewport = Viewport(pageIndex: document.index(for: page), point: point,
                            scale: view.scaleFactor)
    }

    fileprivate func install(_ view: PDFPreviewView, data: Data, revision: String) {
        if self.revision != revision || document == nil {
            document = PDFDocument(data: data)
            self.revision = revision
        }
        view.autoScales = true
        view.document = document
        activeView = view
        if viewport != nil {
            view.restoreAfterLayout = { [weak self, weak view] in
                guard let self, let view, self.activeView === view else { return }
                self.restore(in: view)
            }
        }
    }

    func update(document: PDFDocument, revision: String, view: PDFView) {
        self.document = document
        self.revision = revision
        activeView = view
        capture()
    }

    private func restore(in view: PDFView) {
        guard let viewport, let document = view.document, document.pageCount > 0,
              let page = document.page(at: min(viewport.pageIndex, document.pageCount - 1)) else { return }
        if viewport.scale.isFinite, viewport.scale > 0 {
            view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, viewport.scale))
        }
        guard let point = viewport.point else { view.go(to: page); return }
        let bounds = page.bounds(for: view.displayBox)
        let viewportHeight = view.convert(view.bounds, to: page).height
        view.go(to: PDFDestination(page: page, at: CGPoint(
            x: bounds.minX + point.x * bounds.width,
            y: bounds.minY + point.y * bounds.height + viewportHeight)))
    }
}

private final class PDFPreviewView: PDFView {
    var restoreAfterLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        let restore = restoreAfterLayout
        restoreAfterLayout = nil
        restore?()
    }
}

struct PDFPreview: UIViewRepresentable {
    let data: Data
    var revision: String? = nil
    var session: PDFPreviewSession? = nil
    final class Coordinator {
        var revision: String?
        weak var session: PDFPreviewSession?
        init(session: PDFPreviewSession?) { self.session = session }
    }
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFPreviewView()
        let current = revision ?? ConversationFile.digest(data)
        if let session {
            session.install(view, data: data, revision: current)
        } else {
            view.autoScales = true
            view.document = PDFDocument(data: data)
        }
        context.coordinator.revision = current
        return view
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        guard let session = coordinator.session, session.activeView === view else { return }
        session.capture()
        session.activeView = nil
    }
    func updateUIView(_ view: PDFView, context: Context) {
        let nextRevision = revision ?? ConversationFile.digest(data)
        guard context.coordinator.revision != nextRevision,
              let document = PDFDocument(data: data) else { return }
        session?.capture()
        let destination = view.currentDestination
        let oldPage = destination?.page ?? view.currentPage
        let pageIndex = oldPage.flatMap { view.document?.index(for: $0) } ?? 0
        let scale = view.scaleFactor
        view.document = document
        if scale.isFinite, scale > 0 {
            view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, scale))
        }
        if document.pageCount > 0,
           let page = document.page(at: min(pageIndex, document.pageCount - 1)) {
            if let destination, let oldPage {
                let oldBounds = oldPage.bounds(for: view.displayBox)
                let newBounds = page.bounds(for: view.displayBox)
                if oldBounds.width > 0, oldBounds.height > 0 {
                    let x = (destination.point.x - oldBounds.minX) / oldBounds.width
                    let y = (destination.point.y - oldBounds.minY) / oldBounds.height
                    // PDFKit treats a destination's Y as the top edge of the
                    // viewport; currentDestination reports its bottom edge.
                    let viewportHeight = view.convert(view.bounds, to: page).height
                    view.go(to: PDFDestination(page: page, at: CGPoint(
                        x: newBounds.minX + x * newBounds.width,
                        y: newBounds.minY + y * newBounds.height + viewportHeight)))
                } else { view.go(to: page) }
            } else { view.go(to: page) }
        }
        context.coordinator.revision = nextRevision
        session?.update(document: document, revision: nextRevision, view: view)
    }
}
struct ConstrainedHTML: UIViewRepresentable {
    let html: String
    final class Guard: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
    func makeCoordinator() -> Guard { Guard() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"
        view.loadHTMLString("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>body{font:-apple-system-body}button,input{font:inherit}</style><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">" + html, baseURL: nil)
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}


struct QueueDock: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let attachmentMetadata: [String: ConversationFile]
    let imagePreviews: ToolImagePreviews
    let imagePreviewScope: UUID
    let loadRemoteData: @Sendable (ConversationFile) async throws -> Data
    let openImage: (MessageAttachmentPresentation) -> Void
    let openDocument: ([String]) -> Void
    @State private var editing: QueuedMessage?
    @State private var settingsMessage: QueuedMessage?
    @State private var text = ""
    @State private var busy: String?
    @State private var steering: String?
    @State private var failure: String?
    @FocusState private var focused: Bool

    private func attachments(for item: QueuedMessage) -> [MessageAttachmentPresentation] {
        item.attachmentIds.map { MessageAttachmentPresentation(id: $0, file: attachmentMetadata[$0]) }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if let item = editing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Edit queued message").font(.subheadline.weight(.semibold))
                    TextField("Message", text: $text, axis: .vertical)
                        .lineLimit(2...5).textFieldStyle(.roundedBorder).focused($focused)
                        .accessibilityIdentifier("queued-message-draft")
                        .onChange(of: text) { _, value in model.saveAnswerDraft(["body": value], id: "queue-" + item.id) }
                    HStack {
                        Button("Close") { editing = nil; focused = false }
                        Spacer()
                        Button("Save") {
                            perform(item) {
                                try await model.changeQueue(chat, item: item, body: text)
                                model.saveAnswerDraft([:], id: "queue-" + item.id)
                                editing = nil; focused = false
                            }
                        }.buttonStyle(.borderedProminent)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 65536 || model.previewMode || model.accessEnded)
                    }.frame(minHeight: 44)
                }.disabled(busy != nil)
            } else if !(model.queues[chat.id] ?? []).isEmpty {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(model.queues[chat.id] ?? []) { item in
                        let itemAttachments = attachments(for: item)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(steering == item.id ? "Guiding…" : "Queued").font(.caption).foregroundStyle(.secondary)
                            HStack(alignment: .bottom) {
                                Spacer(minLength: 40)
                                VStack(alignment: .leading, spacing: 4) {
                                    if !itemAttachments.isEmpty {
                                        MessageAttachmentStrip(
                                            attachments: itemAttachments,
                                            imagePreviews: imagePreviews,
                                            imagePreviewScope: imagePreviewScope,
                                            chatID: chat.id,
                                            loadRemoteData: loadRemoteData,
                                            openImage: openImage,
                                            openDocument: { openDocument(item.attachmentIds) }
                                        )
                                    }
                                    Text(item.body).lineLimit(4)
                                }.padding(12)
                                    .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                                    .contextMenu {
                                        if model.agentFamily(chat) == .codex, let turn = model.activeTurn(chat.id) {
                                            Button("Guide instead", systemImage: "arrow.turn.up.right") {
                                                steering = item.id
                                                perform(item) { try await model.changeQueue(chat, item: item, turn: turn) }
                                            }.disabled(model.previewMode || model.accessEnded)
                                        }
                                        Button("Model and permissions", systemImage: "slider.horizontal.3") { settingsMessage = item }
                                            .disabled(chat.botId == nil || model.accessEnded || model.previewMode)
                                        Button("Edit message", systemImage: "pencil") { edit(item) }
                                        Button("Cancel message", systemImage: "trash", role: .destructive) {
                                            perform(item) { try await model.changeQueue(chat, item: item, cancel: true) }
                                        }.disabled(model.previewMode || model.accessEnded)
                                    }
                                    .accessibilityElement(children: itemAttachments.isEmpty ? .combine : .contain)
                                    .accessibilityIdentifier("queued-message:\(item.id)")
                                    .accessibilityLabel("Queued message: " + item.body)
                                    .accessibilityAction(named: "Edit message") { edit(item) }
                            }
                        }
                    }
                }.disabled(busy != nil)
            }
            if busy != nil { ProgressView("Updating message…").font(.caption) }
            if let failure {
                FailureDetails(message: failure)
                Button("Refresh queue") { Task { do { try await model.loadQueue(chat); self.failure = nil } catch { self.failure = "Could not refresh. Reconnect to your Mac and try again." } } }
                    .frame(minHeight: 44).disabled(busy != nil || model.accessEnded || model.previewMode)
            }
        }.frame(maxWidth: .infinity, alignment: .trailing)
            .sheet(item: $settingsMessage) { item in
                NavigationStack {
                    Form {
                        Text(item.body).lineLimit(5)
                        if !model.isSubagent(chat), let botID = chat.botId {
                            ComposerSettings(model: model, chat: chat, botID: botID, queuedMessage: item)
                        }
                    }.navigationTitle("Queued message")
                        .toolbar { Button("Done") { settingsMessage = nil } }
                }
            }
            .onAppear {
                if model.previewMode, ProcessInfo.processInfo.arguments.contains("-queue-edit-preview"), let item = model.queues[chat.id]?.first { edit(item); focused = false }
            }
    }
    private func edit(_ item: QueuedMessage) {
        text = model.answerDraft("queue-" + item.id)["body"] ?? item.body
        editing = item; failure = nil; focused = true
    }
    private func perform(_ item: QueuedMessage, action: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = item.id; failure = nil
        Task {
            defer { busy = nil; steering = nil }
            do { try await action() }
            catch {
                failure = "The message may have changed or started. Refresh the queue, then close and reopen any edit to use the latest version. Your edit stays saved."
                try? await model.loadQueue(chat)
            }
        }
    }
}

struct QueueView: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @Environment(\.dismiss) private var dismiss
    @State private var editing: QueuedMessage?
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            List {
                Text("Messages received by your Mac, waiting to start.").font(.caption).foregroundStyle(.secondary)
                ForEach(model.queues[chat.id] ?? []) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.body)
                        if !item.attachmentIds.isEmpty { Label("\(item.attachmentIds.count) attachments retained", systemImage: "paperclip").font(.caption) }
                        HStack {
                            Button("Edit") { editing = item }.buttonStyle(.borderless)
                            Button("Move up") { move(item) }.buttonStyle(.borderless).disabled(model.queues[chat.id]?.first?.id == item.id)
                            Button("Cancel", role: .destructive) { perform { try await model.changeQueue(chat, item: item, cancel: true) } }.buttonStyle(.borderless)
                        }.frame(minHeight: 44)
                        if model.agentFamily(chat) == .codex, let turn = model.activeTurn(chat.id) { Button("Use as Guide") { perform { try await model.changeQueue(chat, item: item, turn: turn) } }.buttonStyle(.borderless).frame(minHeight: 44) }
                    }
                }
                if let failure { FailureDetails(message: failure); Button("Refresh queue") { refresh() } }
                if busy { ProgressView("Updating queue…") }
                if !busy && (model.queues[chat.id] ?? []).isEmpty { Text("No messages waiting.").foregroundStyle(.secondary) }
            }.disabled(busy || model.accessEnded || model.previewMode)
            .navigationTitle("Queue")
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: $editing) { QueueEditor(model: model, chat: chat, original: $0) }
            .task { refresh() }
        }
    }
    private func refresh() { perform { try await model.loadQueue(chat) } }
    private func move(_ item: QueuedMessage) {
        var items = model.queues[chat.id] ?? []
        guard let index = items.firstIndex(where: { $0.id == item.id }), index > 0 else { return }
        items.swapAt(index, index - 1)
        let order = items
        perform { try await model.reorderQueue(chat, items: order) }
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        busy = true; failure = nil
        Task { defer { busy = false }; do { try await action() } catch { failure = "The queue changed or your Mac is unavailable. Refresh to see what happened. Cancelling pending work does not stop an active response." } }
    }
}
struct QueueEditor: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let original: QueuedMessage
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField("Message", text: $text, axis: .vertical).lineLimit(3...12)
                    .onChange(of: text) { _, value in model.saveAnswerDraft(["body": value], id: "queue-" + original.id) }
                if let failure { FailureDetails(message: failure); Text("Your attempted edit remains saved here. Close and reopen the editor to review the latest queue revision.").font(.caption) }
                if busy { ProgressView("Saving edit…") }
            }.disabled(busy)
            .navigationTitle("Edit queued message")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 65536) }
            }
            .task { text = model.answerDraft("queue-" + original.id)["body"] ?? original.body }
        }
    }
    private func save() {
        busy = true; failure = nil
        Task { defer { busy = false }; do { try await model.changeQueue(chat, item: original, body: text); dismiss() } catch { failure = "The message changed or started. Your edit was not confirmed."; try? await model.loadQueue(chat) } }
    }
}

struct NativeQuestionHistoryRow: View {
    let question: NativeQuestionPresentation
    let rowID: String
    let author: String
    @State private var expanded: Bool
    init(question: NativeQuestionPresentation, rowID: String, author: String) {
        self.question = question; self.rowID = rowID; self.author = author
        _expanded = State(initialValue: !question.isAnswered)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(question.questions.indices, id: \.self) { index in
                let prompt = question.questions[index]
                let answer = question.answers[index]
                VStack(alignment: .leading, spacing: 8) {
                    Text(prompt.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    let options = prompt.options ?? []
                    ForEach(options.indices, id: \.self) { optionIndex in
                        let option = options[optionIndex]
                        Label(option, systemImage: answer == option ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline)
                            .foregroundStyle(answer == option ? .primary : .secondary)
                            .accessibilityLabel(answer == option ? "Your answer: " + option + ", selected" : option)
                    }
                    if let answer, !(prompt.options ?? []).contains(answer) {
                        Text(answer).font(.subheadline).textSelection(.enabled).accessibilityLabel("Your answer: " + answer)
                    }
                }.padding(.vertical, 8)
            }
        } label: {
            let title = question.isAnswered ? "Answered question" : "Question"
            Text(title).accessibilityLabel(author + ": " + title)
        }
        .font(.footnote).padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("native-question-" + rowID)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

struct AsyncQuestionRow: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let question: AsyncQuestion
    @State private var answers: [String: String] = [:]
    @State private var questionIndex = 0
    @State private var showAnswer = false
    private var answerValidation: AsyncAnswerValidationError? {
        AsyncAnswerIntent(answers: question.questions.indices.map { answers[String($0)] ?? "" }, skip: false)
            .validationError(for: question)
    }
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                if question.canAnswer(now: UInt64(context.date.timeIntervalSince1970 * 1000)) {
                    VStack(alignment: .leading, spacing: 8) {
                    QuestionNavigation(index: $questionIndex, count: question.questions.count)
                    ForEach(Array(question.questions.enumerated()).filter { $0.offset == questionIndex }, id: \.offset) { index, prompt in
                        Text(prompt.title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                        ForEach(prompt.options ?? [], id: \.self) { option in
                            ConversationChoice(title: option, selected: answers[String(index)] == option) { answers[String(index)] = option; save() }
                        }
                        TextField("Type an answer", text: Binding(get: { answers[String(index)] ?? "" }, set: { answers[String(index)] = $0; save() }), axis: .vertical).textFieldStyle(.roundedBorder).accessibilityLabel(prompt.title)
                    }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if let error = answerValidation, error != .answerRequired {
                        Text(error.localizedDescription).font(.footnote).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Reply") { Task { await model.replyAsync(question, chat: chat, answers: question.questions.indices.map { answers[String($0)] ?? "" }, skip: false) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.previewMode || answerValidation != nil || model.savedAsyncReplies[question.id] != nil || model.retryableAsyncReplies.contains(question.id))
                        Button("Skip") { Task { await model.replyAsync(question, chat: chat, answers: [], skip: true) } }.buttonStyle(.bordered).disabled(model.previewMode || model.savedAsyncReplies[question.id] != nil || model.retryableAsyncReplies.contains(question.id))
                    }.controlSize(.regular).frame(minHeight: 44)
                } else {
                    DisclosureGroup(question.state == "answered" ? "Answered question" : question.state == "dismissed" ? "Skipped question" : "Expired question", isExpanded: $showAnswer) {
                        ForEach(Array(question.questions.enumerated()), id: \.offset) { index, prompt in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(prompt.title).font(.subheadline.weight(.semibold))
                                let selected = question.response?.answers.indices.contains(index) == true ? question.response?.answers[index] : answers[String(index)]
                                ForEach(prompt.options ?? [], id: \.self) { option in
                                    ConversationChoice(title: option, selected: selected == option) {}.disabled(true)
                                }
                                if let selected, !(prompt.options ?? []).contains(selected) { Text(selected).font(.subheadline) }
                            }.padding(.vertical, 8)
                        }
                    }.font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12)

                }
                if let error = model.attentionErrors[question.id] {
                    FailureDetails(message: error)
                    if model.retryableAsyncReplies.contains(question.id) || model.savedAsyncReplies[question.id] != nil {
                        Button(model.retryableAsyncReplies.contains(question.id) ? "Check saved reply" : "Check status") {
                            Task { await model.replyAsync(question, chat: chat, answers: [], skip: true, retry: true) }
                        }
                    }
                }
                if let saved = model.savedAsyncReplies[question.id] {
                    DisclosureGroup("Saved reply") {
                        Text(saved.skip ? "Skip question" : saved.answers.joined(separator: "\n\n"))
                            .textSelection(.enabled)
                        if !saved.skip {
                            Button("Copy reply", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = saved.answers.joined(separator: "\n\n")
                            }
                        }
                    }
                }
                if model.resolving.contains(question.id) { ProgressView("Saving reply…") }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).disabled(model.resolving.contains(question.id) || model.accessEnded)
        }.task { answers = model.answerDraft(question.id) }
    }
    private func save() { model.saveAnswerDraft(answers, id: question.id) }
}

/// A stable notice keeps questions reachable without replacing the message
/// draft. The sheet owns scrolling, including long forms at large text sizes.
struct QuestionDock: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    @State private var showingSheet = false
    @State private var requestIndex = 0
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let requests = model.requests(for: chat).filter(\.isQuestion)
            let async = (model.asyncQuestions[chat.id] ?? []).filter {
                $0.canAnswer(now: UInt64(context.date.timeIntervalSince1970 * 1000)) || model.attentionErrors[$0.id] != nil
            }
            let count = requests.count + async.count
            if count > 0 {
                Button { showingSheet = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "questionmark.bubble").foregroundStyle(.secondary)
                        Text(count == 1 ? "Question to review" : "\(count) questions to review")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary).padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("question-dock-open")
                .sheet(isPresented: $showingSheet) {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                if count > 1 { QuestionNavigation(index: $requestIndex, count: count) }
                                ForEach(Array(requests.enumerated()).filter { $0.offset == min(requestIndex, count - 1) }, id: \.element.id) { _, request in
                                    AttentionRow(model: model, request: request)
                                }
                                ForEach(Array(async.enumerated()).filter { $0.offset + requests.count == min(requestIndex, count - 1) }, id: \.element.id) { _, question in
                                    AsyncQuestionRow(model: model, chat: chat, question: question)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                        }
                        .navigationTitle(count == 1 ? "Question" : "Questions")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { showingSheet = false } }
                        .onChange(of: count) { _, value in requestIndex = min(requestIndex, max(0, value - 1)) }
                    }
                    .presentationDetents([.large])
                }
            }
        }
    }
}

struct ConversationChoice: View {
    let title: String
    var detail: String? = nil
    var selected: Bool? = nil
    let choose: () -> Void
    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                if let selected {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).foregroundStyle(.primary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .background(selected == true ? Color.accentColor.opacity(0.10) : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected == true ? [.isSelected] : [])
    }
}

struct QuestionNavigation: View {
    @Binding var index: Int
    let count: Int
    var body: some View {
        if count > 1 {
            HStack {
                Text("\(index + 1) of \(count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { index -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .disabled(index == 0).accessibilityLabel("Previous question")
                Button { index += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .disabled(index + 1 >= count).accessibilityLabel("Next question")
            }.buttonStyle(.plain)
        }
    }
}

struct ActivityGroupView: View {
    let rows: [ReadRow]
    let turn: ReadTurn?
    let isLatestSegmentForTurn: Bool
    let isLatestActiveSegment: Bool
    let isProjectConversation: Bool
    let expanded: Bool
    let toggle: () -> Void
    private var lifecycleLabel: String {
        ChatFeedEntry.lifecycleLabel(rows: rows, turn: turn, isLatestSegmentForTurn: isLatestSegmentForTurn,
                                     isLatestActiveSegment: isLatestActiveSegment, isProjectConversation: isProjectConversation)
    }
    private var showsSpinner: Bool {
        turn?.isInProgress == true && isLatestActiveSegment
    }
    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                if showsSpinner {
                    ProgressView().controlSize(.small)
                        .accessibilityIdentifier("activity-progress:" + (rows.first?.id ?? "empty"))
                }
                Text(lifecycleLabel)
                Spacer()
                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold))
            }.font(.subheadline).foregroundStyle(.primary).frame(minHeight: 44)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(lifecycleLabel)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("activity-group:" + (rows.first?.id ?? "empty"))
    }
}

struct ContextCompactionMarker: View {
    let row: ReadRow

    private var presentation: ContextCompactionPresentation {
        row.contextCompactionPresentation ?? .forState("unknown")
    }

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
            HStack(spacing: 6) {
                Image(systemName: presentation.symbol)
                    .font(.caption.weight(.semibold))
                Text(presentation.label)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            .foregroundStyle(.secondary)
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
        .frame(minHeight: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.label)
        .accessibilityIdentifier("context-compaction:" + row.id)
    }
}

private struct CommandDisclosureLabel: View {
    let summary: CommandSummary
    let symbol: String
    let durationIdentifier: String
    @ScaledMetric(relativeTo: .subheadline) private var minimumCommandWidth: CGFloat = 76
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 18

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Duration is secondary. Only show it when the command itself can
            // remain completely visible; otherwise give the row to the
            // tail-truncated command.
            line(includeDuration: true, minimumWidth: minimumCommandWidth, requireFullCommand: true)
            line(includeDuration: false, minimumWidth: minimumCommandWidth)
            // At accessibility sizes in a narrow column, the command is
            // more useful than a decorative terminal icon.
            line(includeDuration: false, minimumWidth: 0, includeIcon: false)
        }
        .font(.subheadline.weight(.medium))
        .frame(minHeight: 24, alignment: .leading)
    }

    @ViewBuilder private func line(includeDuration: Bool, minimumWidth: CGFloat, includeIcon: Bool = true,
                                   requireFullCommand: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if includeIcon { Image(systemName: symbol).frame(width: iconWidth) }
            Text(summary.prefix).fixedSize(horizontal: true, vertical: false)
            if requireFullCommand {
                Text(summary.displayCommand)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(summary.displayCommand)
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: minimumWidth, idealWidth: minimumWidth, maxWidth: .infinity, alignment: .leading)
            }
            if includeDuration, let duration = summary.duration {
                Text("for " + duration)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier(durationIdentifier)
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FileChangeDisclosureLabel: View {
    let summary: FileChangeSummary
    let failed: Bool
    let openFile: ((String) -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    title.lineLimit(3).truncationMode(.middle)
                    counts
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title.lineLimit(1).truncationMode(.middle)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    counts.layoutPriority(1)
                }
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(failed ? Color.red : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var title: some View {
        if let path = summary.path, let openFile {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.action)
                    fileLink(path, open: openFile)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.action).fixedSize(horizontal: true, vertical: false)
                    fileLink(path, open: openFile)
                }
            }
        } else { Text(summary.title) }
    }

    private func fileLink(_ path: String, open: @escaping (String) -> Void) -> some View {
        Button { open(path) } label: {
            Text(summary.target).underline().multilineTextAlignment(.leading)
                .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
        .accessibilityIdentifier("file-change-open:" + path)
        .accessibilityHint("Open this file in Files")
        .accessibilityAddTraits(.isLink)
    }

    private var counts: some View {
        HStack(spacing: 6) {
            if let added = summary.additions {
                Text("+\(added)").accessibilityIdentifier("file-change-additions").foregroundStyle(colorScheme == .dark ? Color.green : Color(red: 0.1, green: 0.42, blue: 0.2))
            }
            if let removed = summary.deletions {
                Text("−\(removed)").accessibilityIdentifier("file-change-deletions").foregroundStyle(colorScheme == .dark ? Color.red : Color(red: 0.75, green: 0.12, blue: 0.16))
            }
        }
        .monospacedDigit()
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SubagentActivityLabel: View {
    let agent: SubagentSummary
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.title).font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(agent.statusLabel).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Label(agent.title, systemImage: "person.2")
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text(agent.statusLabel).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct ActivityItemView: View {
    let row: ReadRow
    let expanded: Bool
    let subagent: SubagentSummary?
    let openSubagent: ((SubagentSummary) -> Void)?
    let openFile: ((String) -> Void)?
    let toggle: () -> Void
    @State private var cached: ActivityPresentation?
    @State private var cachedRevision: DetailSource?
    init(
        row: ReadRow,
        expanded: Bool,
        subagent: SubagentSummary? = nil,
        openSubagent: ((SubagentSummary) -> Void)? = nil,
        openFile: ((String) -> Void)? = nil,
        toggle: @escaping () -> Void
    ) {
        self.row = row
        self.expanded = expanded
        self.subagent = subagent
        self.openSubagent = openSubagent
        self.openFile = openFile
        self.toggle = toggle
    }
    var body: some View {
        let source = DetailSource(payload:row.item?.payload,state:row.item?.state,text:row.item?.text)
        let activity = (expanded && cachedRevision == source ? cached : nil) ?? row.activitySummary
        if let subagent, let openSubagent {
            Button {
                openSubagent(subagent)
            } label: {
                SubagentActivityLabel(agent: subagent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("subagent-row:" + subagent.id)
            .accessibilityLabel(subagent.title + ", " + subagent.statusLabel)
            .accessibilityHint("Open read-only agent task.")
        } else if let activity {
        Group {
        if let file = row.fileChangeSummary {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 0) {
                    FileChangeDisclosureLabel(summary: file, failed: activity.failed, openFile: openFile)
                    Button(action: toggle) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.subheadline.weight(.semibold)).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel((expanded ? "Hide changes: " : "Show changes: ") + file.title)
                    .accessibilityIdentifier("file-change-toggle:" + row.id)
                }
                if expanded {
                    ForEach(Array(activity.details.enumerated()), id: \.offset) { _, detail in
                        if !["Files", "Added lines", "Removed lines"].contains(detail.title) || !activity.details.contains(where: \.isDiff) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let path = detail.filePath, let openFile {
                                    Button { openFile(path) } label: { Text(detail.title).underline().frame(minHeight: 44, alignment: .leading).contentShape(Rectangle()) }
                                        .font(.caption).buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                        .accessibilityIdentifier("file-change-detail-open:" + path)
                                        .accessibilityHint("Open this file in Files")
                                        .accessibilityAddTraits(.isLink)
                                } else { Text(detail.title).font(.caption).foregroundStyle(.secondary) }
                                ToolTextPanel(text: detail.text, diff: detail.isDiff)
                            }
                        }
                    }
                }
            }
        } else {
        DisclosureGroup(isExpanded: Binding(get: { expanded }, set: { _ in toggle() })) {
            if expanded {
            VStack(alignment: .leading, spacing: 10) {
                if activity.kind == "commandExecution" {
                    ToolTextPanel(text: "$ " + (activity.details.first { $0.title == "Command" }?.text ?? "")
                        + (activity.details.first { $0.title == "Output" }.map { "\n\n" + $0.text } ?? ""))
                    if activity.failed, let exit = activity.details.first(where: { $0.title == "Exit code" }) {
                        Text("Exited with code \(exit.text)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = activity.details.first(where: { $0.title == "Error" }) {
                        Text(error.text).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(activity.details.enumerated()), id: \.offset) { _, detail in
                        if activity.kind != "fileChange" || !["Files", "Added lines", "Removed lines"].contains(detail.title) || !activity.details.contains(where: \.isDiff) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(detail.title).font(.caption).foregroundStyle(.secondary)
                                ToolTextPanel(text: detail.text, diff: detail.isDiff)
                            }
                        }
                    }
                }
            }.padding(.top, 6)
            }
        } label: {
            if activity.kind == "commandExecution", let command = row.commandSummary {
                CommandDisclosureLabel(summary: command, symbol: activity.symbol,
                                       durationIdentifier: "command-duration:" + row.id)
                    .foregroundStyle(activity.failed ? Color.red : Color.primary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Label(activity.title, systemImage: activity.symbol).font(.subheadline.weight(.medium))
                    Spacer()
                    Text(activity.status).font(.caption)
                        .foregroundStyle(activity.failed ? Color.red : Color.secondary)
                }.foregroundStyle(.primary)
            }
        }
        .tint(.primary)
        }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.commandSummary?.accessibilityLabel ?? row.fileChangeSummary?.accessibilityLabel ?? activity.title)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("activity-detail")
        .task(id: DetailRevision(expanded: expanded, source:source)) {
            guard expanded, cachedRevision != source else { return }
            let value = row
            let presentation = await Task.detached(priority: .userInitiated) { value.activity }.value
            guard !Task.isCancelled else { return }
            cachedRevision=source; cached=presentation
        }
        }
    }
    private struct DetailRevision: Equatable {
        let expanded: Bool
        let source: DetailSource
    }
    private struct DetailSource: Equatable {
        let payload: [String: ThreadValue]?
        let state: String?
        let text: String?
    }
}


/// Tool content remains selectable, inert text with bounded scrolling.
struct ToolTextPanel: View {
    let text: String
    var diff = false
    var body: some View {
        ToolTextView(text:text,diff:diff)
        // Keep the full selectable text out of the accessibility tree. UIKit
        // otherwise serializes thousands of lines for every XCTest/VoiceOver
        // snapshot, even though the visible viewport is bounded below.
        .accessibilityHidden(true)
        .frame(height: min(260, CGFloat(max(1, text.prefix(2000).filter { $0 == "\n" }.count + 1)) * 20 + 20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("tool-output")
        .accessibilityLabel(diff ? "Diff output" : "Command output")
        .accessibilityValue("Full text is available in the scrollable viewer.")
        .accessibilityHint("Use the copy action to copy the complete text.")
        .accessibilityAction(named: Text(diff ? "Copy full diff" : "Copy full output")) {
            UIPasteboard.general.string = text
        }
    }
}

/// TextKit lays out a bounded viewport instead of thousands of SwiftUI diff rows.
private struct ToolTextView: UIViewRepresentable {
    let text: String
    let diff: Bool
    func makeUIView(context: Context) -> UITextView {
        let view=UITextView(usingTextLayoutManager: false)
        view.isEditable=false; view.isSelectable=true; view.backgroundColor = .clear
        view.textContainerInset=UIEdgeInsets(top:10,left:10,bottom:10,right:10)
        view.font = .monospacedSystemFont(ofSize:16,weight:.regular)
        view.adjustsFontForContentSizeCategory=true
        view.isAccessibilityElement=false
        view.accessibilityElementsHidden=true
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        guard context.coordinator.text != text || context.coordinator.diff != diff else { return }
        context.coordinator.text=text; context.coordinator.diff=diff
        let output=NSMutableAttributedString(string:text,attributes:[.font:UIFontMetrics(forTextStyle:.callout).scaledFont(for:.monospacedSystemFont(ofSize:16,weight:.regular)),.foregroundColor:UIColor.label])
        if diff {
            let source=text as NSString
            source.enumerateSubstrings(in:NSRange(location:0,length:source.length),options:.byLines) { line, range, _, _ in
                if let line, line.hasPrefix("+") || line.hasPrefix("-") {
                    output.addAttribute(.backgroundColor,value:(line.hasPrefix("+") ? UIColor.systemGreen : UIColor.systemRed).withAlphaComponent(0.14),range:range)
                }
            }
        }
        view.attributedText=output
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var text: String?; var diff=false }
}


struct ToolFilePreview: View {
    let model: ConnectionModel
    let chat: ChatSummary
    let file: ConversationFile
    @State private var thumbnail: UIImage?
    @State private var failed = false
    @State private var showingPreview = false
    @State private var showingPhoto = false
    @State private var retry = 0
    private var request: ToolImageRequest { ToolImageRequest(scope: model.imagePreviewScope, chatID: chat.id, file: file, retry: retry) }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if PhotoViewerRouting.isImage(file) { showingPhoto = true }
                else { showingPreview = true }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    if file.mimeType?.hasPrefix("image/") == true {
                        ToolImageCanvas(image: thumbnail, failed: failed)
                    } else {
                        Label(file.name, systemImage: "doc")
                            .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                    }
                }
            }.buttonStyle(.plain).accessibilityLabel("Preview \(file.name)")
                .accessibilityIdentifier("tool-image:\(file.id)")
                .accessibilityValue(file.mimeType?.hasPrefix("image/") == true ? (thumbnail != nil ? "Loaded" : failed ? "Unavailable" : "Loading") : "")
                .overlay(alignment: .topLeading) {
                    if failed {
                        Button("Retry preview", systemImage: "arrow.clockwise") { retry += 1 }
                            .font(.caption).frame(minHeight: 44).padding(8)
                    }
                }
        }
        .task(id: request) { await load(request) }
        .onDisappear { thumbnail = nil }
        .sheet(isPresented: $showingPreview) { PreviewDeck(model: model, chat: chat, initialFile: file) }
        .fullScreenCover(isPresented: $showingPhoto) { PhotoViewer(model: model, chat: chat, file: file) }
    }
    private func load(_ request: ToolImageRequest) async {
        thumbnail = nil; failed = false
        guard file.mimeType?.hasPrefix("image/") == true else { return }
        do {
            let image = try await model.imagePreviews.image(for: request) { [model, file, chat] in
                try await model.download(file, chat: chat)
            }
            try Task.checkCancellation()
            guard request == self.request else { return }
            thumbnail = image
        } catch {
            guard !Task.isCancelled, request == self.request else { return }
            failed = true
        }
    }
}

/// Reserve the same space before, during and after loading. Lazy-stack scroll
/// anchoring must not compensate for an image growing underneath a gesture.
struct ToolImageCanvas: View {
    let image: UIImage?
    let failed: Bool
    var body: some View {
        Color(uiColor: .secondarySystemBackground)
            .frame(maxWidth: 360).frame(height: 220)
            .overlay {
                if let image { Image(uiImage: image).resizable().scaledToFit() }
                else if !failed { ProgressView() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct ToolImageRequest: Hashable, Sendable {
    let scope: UUID
    let chatID: String
    let fileID: String
    let sha256: String?
    let mimeType: String?
    let byteSize: Int?
    let state: String
    let updatedAt: String
    let retry: Int
    init(scope: UUID, chatID: String, file: ConversationFile, retry: Int = 0) {
        self.init(scope: scope, chatID: chatID, fileID: file.id, sha256: file.sha256,
            mimeType: file.mimeType, byteSize: file.byteSize, state: file.state,
            updatedAt: file.updatedAt, retry: retry)
    }
    init(scope: UUID, chatID: String, fileID: String, sha256: String?, mimeType: String?, byteSize: Int?, state: String, updatedAt: String, retry: Int = 0) {
        self.scope = scope; self.chatID = chatID; self.fileID = fileID
        self.sha256 = sha256; self.mimeType = mimeType; self.byteSize = byteSize
        self.state = state; self.updatedAt = updatedAt; self.retry = retry
    }
}

/// One connection owns a small disposable cache and at most two downloads/decodes.
/// Requests shared by visible rows are deduplicated; leaving the screen cancels
/// work once its last consumer disappears, including work still in the queue.
@MainActor final class ToolImagePreviews {
    private struct Job {
        let id = UUID()
        let load: @Sendable () async throws -> Data
        var waiters: [UUID: CheckedContinuation<UIImage, Error>] = [:]
        var task: Task<UIImage, Error>?
    }
    private let maximumBytes: Int
    private var cache: [ToolImageRequest: UIImage] = [:]
    private var order: [ToolImageRequest] = []
    private(set) var cachedBytes = 0
    private var jobs: [ToolImageRequest: Job] = [:]
    private var queue: [ToolImageRequest] = []
    private var running = 0
    init(maximumBytes: Int = 16 * 1024 * 1024) { self.maximumBytes = maximumBytes }

    func image(for key: ToolImageRequest, load: @escaping @Sendable () async throws -> Data) async throws -> UIImage {
        try Task.checkCancellation()
        if let image = cache[key] {
            order.removeAll { $0 == key }; order.append(key)
            #if WONDER_DIAGNOSTICS
            DiagnosticJournal.shared.record(DiagnosticEvent(operation: "image.cache", phase: "hit", count: 1))
            #endif
            return image
        }
        let consumer = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if jobs[key] == nil { jobs[key] = Job(load: load); queue.append(key) }
                jobs[key]?.waiters[consumer] = continuation
                startNext()
            }
        } onCancel: {
            Task { @MainActor in self.cancel(key, consumer: consumer) }
        }
    }

    func invalidate() {
        removeCachedImages()
        for job in jobs.values {
            job.task?.cancel()
            for waiter in job.waiters.values { waiter.resume(throwing: CancellationError()) }
        }
        jobs.removeAll(); queue.removeAll()
    }

    func removeCachedImages() { cache.removeAll(); order.removeAll(); cachedBytes = 0 }

    private func cancel(_ key: ToolImageRequest, consumer: UUID) {
        guard let waiter = jobs[key]?.waiters.removeValue(forKey: consumer) else { return }
        waiter.resume(throwing: CancellationError())
        if jobs[key]?.waiters.isEmpty == true {
            jobs.removeValue(forKey: key)?.task?.cancel()
            queue.removeAll { $0 == key }
        }
    }

    private func startNext() {
        while running < 2, !queue.isEmpty {
            let key = queue.removeFirst()
            guard let job = jobs[key] else { continue }
            running += 1
            let worker = Task.detached(priority: .utility) { [load = job.load] in
                #if WONDER_DIAGNOSTICS
                let started = ProcessInfo.processInfo.systemUptime
                #endif
                let data = try await load()
                try Task.checkCancellation()
                #if WONDER_DIAGNOSTICS
                let received = ProcessInfo.processInfo.systemUptime
                DiagnosticJournal.shared.record(DiagnosticEvent(operation: "image.download", durationMs: (received - started) * 1000, bytes: UInt64(data.count)))
                #endif
                guard let image = ToolPreviewImage.decode(data) else { throw FileFailure.unsupported }
                #if WONDER_DIAGNOSTICS
                DiagnosticJournal.shared.record(DiagnosticEvent(operation: "image.decode", durationMs: (ProcessInfo.processInfo.systemUptime - received) * 1000))
                #endif
                try Task.checkCancellation()
                return image
            }
            jobs[key]?.task = worker
            Task {
                let result = await worker.result
                running -= 1
                if jobs[key]?.id == job.id, let finished = jobs.removeValue(forKey: key) {
                    if case .success(let image) = result { retain(image, for: key) }
                    for waiter in finished.waiters.values { waiter.resume(with: result) }
                }
                startNext()
            }
        }
    }

    private func retain(_ image: UIImage, for key: ToolImageRequest) {
        let cost = Self.cost(image)
        guard cost <= maximumBytes else { return }
        while cachedBytes + cost > maximumBytes || order.count >= 12 {
            guard !order.isEmpty else { break }
            if let removed = cache.removeValue(forKey: order.removeFirst()) { cachedBytes -= Self.cost(removed) }
        }
        cache[key] = image; order.append(key); cachedBytes += cost
    }
    private static func cost(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }
}

enum ToolPreviewImage {
    /// A 360-point thumbnail needs at most 1080 pixels, even on a 3x display.
    nonisolated static func decode(_ data: Data) -> UIImage? {
        autoreleasepool {
            guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:1080,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else { return nil }
            return UIImage(cgImage:image)
        }
    }
}

enum PhotoViewerImage {
    /// Full-screen viewing is bounded independently from the 1080px thumbnail.
    /// A 4096px maximum dimension keeps the decoded image near the 64 MiB budget;
    /// the original verified bytes remain available separately for Copy image.
    nonisolated static func decode(_ data: Data) -> UIImage? {
        autoreleasepool {
            guard data.count <= 8 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary),
                  Int64(image.width) * Int64(image.height) <= 16_777_216,
                  Int64(image.bytesPerRow) * Int64(image.height) <= 64 * 1024 * 1024 else { return nil }
            return UIImage(cgImage: image)
        }
    }
}

private struct PhotoZoomView: UIViewRepresentable {
    let image: UIImage
    let imageID: String
    @Binding var zoomScale: CGFloat
    let reduceMotion: Bool
    var preservePosition = false

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale, reduceMotion: reduceMotion)
    }

    func makeUIView(context: Context) -> PhotoZoomScrollView {
        let view = PhotoZoomScrollView()
        view.backgroundColor = .clear
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 4
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        view.alwaysBounceVertical = true
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.isAccessibilityElement = false
        view.photoImageView = imageView
        view.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        context.coordinator.install(image: image, id: imageID, in: view)
        return view
    }

    func updateUIView(_ view: PhotoZoomScrollView, context: Context) {
        // Do not touch zoomScale or contentOffset for an ordinary SwiftUI update.
        // The source ID is the only event that starts a new viewing session.
        if view.imageID != imageID {
            context.coordinator.install(image: image, id: imageID, in: view, preservePosition: preservePosition)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        private let zoomScale: Binding<CGFloat>
        private let reduceMotion: Bool
        private var isInstallingImage = false

        init(zoomScale: Binding<CGFloat>, reduceMotion: Bool) {
            self.zoomScale = zoomScale
            self.reduceMotion = reduceMotion
        }

        func install(image: UIImage, id: String, in scrollView: PhotoZoomScrollView,
                     preservePosition: Bool = false) {
            isInstallingImage = true
            defer { isInstallingImage = false }
            let oldSize = scrollView.contentSize
            let oldCenter = CGPoint(x: (scrollView.contentOffset.x + scrollView.bounds.midX) / max(oldSize.width, 1),
                                    y: (scrollView.contentOffset.y + scrollView.bounds.midY) / max(oldSize.height, 1))
            let oldZoom = scrollView.zoomScale
            scrollView.imageID = id
            scrollView.photoImageView?.image = image
            scrollView.minimumZoomScale = 1
            scrollView.maximumZoomScale = 4
            scrollView.photoImageView?.frame = scrollView.bounds
            scrollView.contentSize = scrollView.bounds.size
            scrollView.setZoomScale(preservePosition ? min(4, max(1, oldZoom)) : 1, animated: false)
            if preservePosition {
                let width = max(0, scrollView.contentSize.width - scrollView.bounds.width)
                let height = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                scrollView.contentOffset = CGPoint(
                    x: min(width, max(0, oldCenter.x * scrollView.contentSize.width - scrollView.bounds.midX)),
                    y: min(height, max(0, oldCenter.y * scrollView.contentSize.height - scrollView.bounds.midY)))
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? PhotoZoomScrollView)?.photoImageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard !isInstallingImage, zoomScale.wrappedValue != scrollView.zoomScale else { return }
            zoomScale.wrappedValue = scrollView.zoomScale
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? PhotoZoomScrollView else { return }
            let target = scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 ? scrollView.minimumZoomScale : min(2, scrollView.maximumZoomScale)
            scrollView.setZoomScale(target, animated: !reduceMotion)
        }
    }
}

private final class PhotoZoomScrollView: UIScrollView {
    var photoImageView: UIImageView?
    var imageID: String?

    override func layoutSubviews() {
        super.layoutSubviews()
        guard zoomScale <= minimumZoomScale + 0.01 else { return }
        photoImageView?.frame = bounds
        contentSize = bounds.size
    }
}


/// Bot defaults live beside the draft; successful saves are reflected across clients.
struct ComposerSettings: View {
    @ObservedObject var model: ConnectionModel
    let chat: ChatSummary
    let botID: String
    var queuedMessage: QueuedMessage? = nil
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var options: BotOptions?
    @State private var failure: String?
    @State private var loading = false
    @State private var loadFailed = false
    @State private var showingModel = false
    @State private var modelDetent: PresentationDetent = .large
    private var queued: QueuedMessage? { queuedMessage.flatMap { item in model.queues[chat.id]?.first { $0.id == item.id } } }
    private var bot: ManagedBot? {
        guard let bot = model.managedBots.first(where: { $0.id == botID }) else { return nil }
        guard let settings = queued?.executionSettings,
              let data = try? JSONEncoder().encode(bot),
              var fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return bot }
        fields["model"] = settings.model ?? ""
        fields["reasoningEffort"] = settings.reasoningEffort ?? ""
        fields["serviceTier"] = settings.serviceTier ?? "default"
        fields["permissionMode"] = settings.permissionMode as Any? ?? NSNull()
        fields["approvalMode"] = settings.approvalMode as Any? ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: fields)).flatMap { try? JSONDecoder().decode(ManagedBot.self, from: $0) } ?? bot
    }
    private var approvalTarget: ComposerApprovalTarget {
        ComposerApprovalTarget(conversationID: chat.id, botID: botID, queuedMessageID: queuedMessage?.id)
    }
    private var approvalChange: ComposerApprovalChange? { model.approvalChange(approvalTarget) }
    private var saving: Bool { model.savingComposerSettings.contains(chat.id) }
    private var unavailable: Bool { saving || approvalChange?.saving == true || loading || bot == nil || model.accessEnded || (queuedMessage != nil && queued == nil) }
    private var selectedModel: BotOptions.Model? { options?.models.first { $0.id == bot?.model } }
    private var selectedServiceTier: BotOptions.Choice? {
        guard let selectedModel else { return nil }
        let id = bot?.serviceTier ?? selectedModel.defaultServiceTier ?? "default"
        return selectedModel.serviceTiers?.first { $0.id == id }
    }
    private var modelTitle: String {
        let name = selectedModel?.displayName ?? bot?.model ?? "Default model"
        let effort = selectedModel?.reasoningEfforts.first { $0.id == bot?.reasoningEffort }?.label.capitalized
        let speed = selectedServiceTier.flatMap { $0.id == "default" ? nil : $0.label.capitalized }
        return [name, effort, speed].compactMap { $0 }.joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                permissionMenu
                Spacer(minLength: 0)
                modelButton
            }
            if saving { ProgressView("Saving…").font(.caption).padding(.horizontal, 12) }
            if options != nil && options?.approvalModes == nil { Text("Update Wonder on your Mac to change approval settings.").font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 12) }
            if let failure, options != nil {
                FailureDetails("Settings not saved", message: failure).padding(.horizontal, 12)
            }
            if let change = approvalChange, let error = change.failure {
                HStack {
                    Text(error).font(.caption)
                    Button("Retry") { model.setApprovalMode(change.desired, target: approvalTarget, chat: chat) }
                }.padding(.horizontal, 12)
                    .accessibilityIdentifier("composer-approval-error")
            }
        }
        .task(id: model.assignmentScope + ":" + botID + ":" + (bot?.modelSelectionRevision == nil ? "started" : "new")) { options = nil; await load() }
        .sheet(isPresented: $showingModel) {
            NavigationStack {
                Form {
                    if options == nil {
                        Section {
                            if loading { ProgressView() }
                            else { Button("Reload models") { Task { await load() } } }
                        }
                    } else {
                        Section("Model") {
                            modelChoice("Default model", id: "")
                            ForEach(options?.models.filter { !$0.hidden && (bot?.modelSelectionRevision != nil || $0.family == (bot?.family ?? .codex)) } ?? []) { option in modelChoice(option.displayName, id: option.id) }
                        }.disabled(unavailable || model.previewMode)
                    }
                    if queuedMessage == nil && model.botWorking(chat.id) {
                        Section { Text(bot?.family == .claude ? "Changes apply to new queued messages." : "Changes apply to new queued messages. Guide continues the current response with its existing settings.").font(.footnote) }
                    }
                    if let selectedModel, !selectedModel.reasoningEfforts.isEmpty {
                        Section("Reasoning") {
                            effortChoice("Default", id: "")
                            ForEach(selectedModel.reasoningEfforts) { option in effortChoice(option.label.capitalized, id: option.id) }
                        }.disabled(unavailable || model.previewMode)
                        if let tiers = selectedModel.serviceTiers, tiers.count > 1 {
                            Section("Speed") {
                                ForEach(tiers) { option in speedChoice(option) }
                            }.disabled(unavailable || model.previewMode)
                        }
                    }
                    if loadFailed, options != nil { Button("Reload models") { Task { await load() } } }
                    if let failure { FailureDetails("Settings not saved", message: failure) }
                    if saving { ProgressView("Saving…") }
                }
                .navigationTitle("Model").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { showingModel = false } }
            }.presentationDetents([.medium, .large], selection: $modelDetent).presentationDragIndicator(.visible)
        }
    }
    private var permissionMenu: some View {
        ApprovalModeMenu(
            selection: Binding(get: { approvalMode }, set: { _ in }),
            options: options?.approvalChoices(model: bot?.model),
            isDisabled: saving || loading || bot == nil || model.accessEnded || model.previewMode || (queuedMessage != nil && queued == nil),
            family: bot?.family ?? .codex,
            onChange: { mode in model.setApprovalMode(mode, target: approvalTarget, chat: chat) }
        ) {
            Image(systemName: "shield").font(.system(size: 18))
                .frame(width: 44, height: 44)
                .foregroundStyle(approvalMode == .fullAccess ? Color.orange : Color.primary)
        }
        .accessibilityLabel("Approval").accessibilityValue(approvalMode.title)
        .accessibilityIdentifier("composer-permissions")
    }
    private var approvalMode: BotApprovalMode {
        if let change = approvalChange, change.saving { return change.desired }
        return bot?.approvalMode.flatMap(BotApprovalMode.init(rawValue:)) ?? (bot?.permissionMode == BotPermissionMode.fullAccess.rawValue ? .fullAccess : .askForApproval) }
    private var modelButton: some View {
        Button { showingModel = true } label: {
            Group {
                if typeSize.isAccessibilitySize { Image(systemName: "slider.horizontal.3").font(.system(size: 20)) }
                else { HStack(spacing: 4) {
                    Text(selectedModel?.displayName ?? bot?.model ?? "Model").lineLimit(1)
                    Image(systemName: "chevron.down").imageScale(.small)
                }.font(.subheadline) }
            }.padding(.horizontal, 4).frame(minWidth: 44, minHeight: 44)
        }.disabled(saving || approvalChange?.saving == true).accessibilityLabel("Model").accessibilityValue(modelTitle).accessibilityIdentifier("composer-model")
    }
    private func modelChoice(_ title: String, id: String) -> some View {
        Button { Task { await save(["model": id, "reasoningEffort": "", "serviceTier": ""]) } } label: {
            HStack { Text(title); Spacer(); if (bot?.model ?? "") == id { Image(systemName: "checkmark") } }
        }
    }
    private func effortChoice(_ title: String, id: String) -> some View {
        Button { Task { await save(["reasoningEffort": id]) } } label: {
            HStack { Text(title); Spacer(); if (bot?.reasoningEffort ?? "") == id { Image(systemName: "checkmark") } }
        }
    }
    private func speedChoice(_ option: BotOptions.Choice) -> some View {
        let selected = (bot?.serviceTier ?? selectedModel?.defaultServiceTier ?? "default") == option.id
        let title = option.id == "default" ? "Default" : option.label.capitalized
        let detail = option.description?
            .replacingOccurrences(of: "Standard speed, standard usage", with: "Default speed and usage")
            .replacingOccurrences(of: "2x", with: "2×")
            .replacingOccurrences(of: "1.5x", with: "1.5×")
        return Button { Task { await save(["serviceTier": option.id]) } } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                if selected { Image(systemName: "checkmark") }
            }
        }
    }
    private func load() async {
        if model.previewMode {
            if ProcessInfo.processInfo.arguments.contains("-settings-unavailable-preview") { loadFailed = true; return }
            let fixture: [String: Any] = ["models": [["id":"claude:claude-haiku-4-5","displayName":"Claude Haiku 4.5","hidden":false,"reasoningEfforts":[]], ["id":"preview-model", "displayName":"GPT-6 Astra", "hidden":false, "reasoningEfforts":[["id":"low","label":"Low"],["id":"medium","label":"Medium"],["id":"high","label":"High"]], "serviceTiers":[["id":"default","label":"Standard","description":"Standard speed, standard usage"],["id":"priority","label":"Fast","description":"2x speed, increased usage"]]]], "permissionModes": BotPermissionMode.allCases.map { ["id":$0.rawValue,"allowed":true] as [String:Any] }, "approvalModes": BotApprovalMode.allCases.map { ["id":$0.rawValue,"allowed":true] as [String:Any] }, "timezone":"America/New_York", "allowedApprovalPolicies":["on-request"]]
            options = try? JSONDecoder().decode(BotOptions.self, from: JSONSerialization.data(withJSONObject: fixture))
            return
        }
        loading = true; loadFailed = false; defer { loading = false }
        do {
            let query = queuedMessage.map { "?queuedMessageId=" + ConnectionModel.escape($0.id) } ?? ""
            options = try await model.manage("/api/v1/conversations/\(ConnectionModel.escape(chat.id))/composer-options" + query)
            await model.loadChats(force: true)
            failure = nil
        }
        catch { loadFailed = true }
    }
    private func save(_ values: [String: String]) async {
        guard !unavailable, !model.previewMode else { return }
        let scope = model.assignmentScope
        model.savingComposerSettings.insert(chat.id); failure = nil
        defer { if scope == model.assignmentScope { model.savingComposerSettings.remove(chat.id) } }
        do {
            if queuedMessage != nil {
                guard let queued else { throw PairingFailure.response(409) }
                struct Empty: Decodable, Sendable {}
                let body = try JSONSerialization.data(withJSONObject: ["expectedRevision": queued.revision, "settings": values])
                let _: Empty = try await model.manage("/api/v1/conversations/\(ConnectionModel.escape(chat.id))/queue/\(ConnectionModel.escape(queued.id))", method: "POST", body: body)
                try await model.loadQueue(chat)
                await load()
                return
            }
            var payload: [String: Any] = values
            if let revision = bot?.modelSelectionRevision { payload["modelSelectionRevision"] = revision }
            let saved: ManagedBot = try await model.manage("/api/v1/bots/\(ConnectionModel.escape(botID))", method: "PATCH", body: JSONSerialization.data(withJSONObject: payload))
            guard scope == model.assignmentScope, !model.accessEnded else { return }
            model.applyConfirmedManagedBot(saved)
            await load()
        } catch {
            guard scope == model.assignmentScope else { return }
            if case PairingFailure.response(409) = error { failure = "Settings could not be changed. Refresh and try again." }
            else { failure = "Settings were not confirmed. Reload before trying again." }
            if queuedMessage != nil { try? await model.loadQueue(chat) }
            await model.loadChats(force: true)
        }
    }
}
