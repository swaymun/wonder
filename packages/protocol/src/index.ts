export type DeliveryState =
  | "draft_on_device"
  | "submitting"
  | "accepted_by_wonder"
  | "dispatching_to_codex"
  | "accepted_by_codex"
  | "streaming"
  | "completed"
  | "interrupted"
  | "failed"
  | "uncertain"
  | "safe_to_retry";

export const SCIENCE_AVATAR_SOURCE_VERSION = "science-avatar-v1" as const;
export const SCIENCE_AVATAR_SOURCE_HASH = "9324e397b3c5d27dd693bac25f5a776d451fb7ad941f7567f21446e79fc63c3a" as const;
export const SCIENCE_AVATAR_SHAPES = ["sun", "orbit", "nova", "comet", "prism", "atom", "luna"] as const;
export const SCIENCE_AVATAR_PALETTES = ["amber", "coral", "rose", "violet", "indigo", "ocean", "sky", "teal", "mint", "olive", "cocoa", "slate"] as const;
export type ScienceAvatarShape = (typeof SCIENCE_AVATAR_SHAPES)[number];
export type ScienceAvatarPalette = (typeof SCIENCE_AVATAR_PALETTES)[number];

export interface ConversationSummary {
  conversationId: string;
  botId: string | null;
  title: string;
  lastMessagePreview: string | null;
  lastMessageAt: string | null;
  messageCount: number;
  deliveryState: DeliveryState | null;
  hasUnread: boolean;
  isArchived: boolean;
  isPinned: boolean;
}

export type ConversationListResponse = ConversationSummary[];

export interface BotSummary {
  id: string;
  name: string;
  role: string;
  systemPrompt: string;
  workspacePath: string;
  permissionProfile: string;
  /** Legacy scope axis; retained for compatibility with older hosts. */
  permissionMode?: "read-only" | "workspace" | "full-access" | null;
  /** Product approval axis. Older hosts omit this field. */
  approvalMode?: "ask-for-approval" | "approve-for-me" | "full-access" | null;
  workingDirectory?: string | null;
  avatarColor?: string | null;
  /** Stable science character identifier; older hosts omit it. */
  avatarShape?: string | null;
  /** Stable fixed-palette identifier; older/future hosts may omit or extend it. */
  avatarPalette?: string | null;
  conversationId?: string | null;
  model: string | null;
  reasoningEffort: string | null;
  serviceTier: string | null;
  isArchived: boolean;
}

export type BotListResponse = BotSummary[];

export type ApprovalMode = "ask-for-approval" | "approve-for-me" | "full-access";

export interface ApprovalModeOption {
  id: ApprovalMode;
  allowed: boolean;
}

export interface ComposerOptionsQuery {
  /** Frozen settings for a pending message owned by this conversation. */
  queuedMessageId?: string;
}

export interface ComposerOptionsResponse {
  /** Present on host-wide /bot-options responses; scoped responses may omit it. */
  groupCollaboration?: boolean;
  models: unknown[];
  permissionProfiles?: unknown[];
  permissionModes?: Array<{ id: string; allowed: boolean }>;
  /** Omitted by older hosts; absence is an unavailable/update state. */
  approvalModes?: ApprovalModeOption[];
  /** Omitted by older composer-options responses. */
  timezone?: string;
  allowedApprovalPolicies: string[];
  allowedApprovalReviewers?: string[];
}

export interface CreateBotRequest {
  permissionMode?: "read-only" | "workspace" | "full-access" | null;
  approvalMode?: ApprovalMode | null;
  readRoots?: string[];
  writeRoots?: string[];
  clientRequestId?: string | null;
  avatarColor?: string | null;
  avatarShape?: ScienceAvatarShape | null;
  avatarPalette?: ScienceAvatarPalette | null;
  workingDirectory?: string | null;
  name: string;
  role: string;
  systemPrompt: string;
  model?: string | null;
  reasoningEffort?: string | null;
  serviceTier?: string | null;
}

export interface UpdateBotRequest {
  permissionMode?: "read-only" | "workspace" | "full-access" | null;
  approvalMode?: ApprovalMode | null;
  avatarColor?: string | null;
  avatarShape?: ScienceAvatarShape | null;
  avatarPalette?: ScienceAvatarPalette | null;
  workingDirectory?: string | null;
  name?: string;
  role?: string;
  systemPrompt?: string;
  model?: string | null;
  reasoningEffort?: string | null;
  serviceTier?: string | null;
}

export interface QueuedExecutionSettings {
  model?: string | null;
  reasoningEffort?: string | null;
  serviceTier?: string | null;
  permissionMode?: "read-only" | "workspace" | "full-access" | null;
  approvalMode?: ApprovalMode | null;
  /** Canonical working directory frozen when this queued item was accepted. */
  workingDirectory?: string | null;
}

export interface QueuedMessage {
  id: string;
  clientMessageId: string;
  body: string;
  revision: number;
  attachmentIds: string[];
  executionSettings?: QueuedExecutionSettings;
}

export interface QueueEditRequest {
  expectedRevision: number;
  settings?: QueuedExecutionSettings;
  body?: string | null;
  cancel?: boolean;
  expectedTurnId?: string | null;
}

export interface QueueReorderRequest {
  items: Array<[string, number]>;
}

export type SearchResultKind = "bot" | "channel" | "conversation" | "message" | "assistant_message" | "file";

export interface SearchResult {
  kind: SearchResultKind;
  id: string;
  title: string;
  snippet: string | null;
  conversationId: string | null;
  botId: string | null;
  updatedAt: string;
  deepLink: string;
}

export type SearchResponse = SearchResult[];

export interface DeviceSummary {
  id: string;
  label: string;
  role: "owner";
  lastSeenAt: string | null;
  revokedAt: string | null;
  sessionExpiresAtMs: number | null;
}

export interface RenameDeviceRequest {
  label: string;
  actionNonce: string;
  issuedAtMs: number;
  signature: string;
}

export interface ConversationSettingsResponse {
  effective: ConversationSettingsValues;
  overrides: ConversationSettingsOverrides;
  botDefaults: ConversationSettingsValues;
}

export interface ConversationSettingsValues {
  model: string | null;
  effort: string | null;
  serviceTier: string | null;
  permissionProfile: string;
  approvalMode: ApprovalMode | null;
  approvalPolicy: string;
  approvalsReviewer: string;
}

export interface ConversationSettingsOverrides {
  model: string | null;
  effort: string | null;
  serviceTier: string | null;
  permissionProfile: string | null;
}

export interface ConversationSettingsPatch {
  model?: string | null;
  effort?: string | null;
  serviceTier?: string | null;
  permissionProfile?: string | null;
  actionNonce: string;
  issuedAtMs: number;
  signature: string;
}

export type DeviceListResponse = DeviceSummary[];

export type ChannelMemberRole = "coordinator" | "worker";

export interface ChannelMember {
  botId: string;
  botName: string;
  role: ChannelMemberRole;
  position: number;
}

export interface ChannelSummary {
  id: string;
  conversationId: string;
  name: string;
  description: string | null;
  coordinatorBotId: string;
  isArchived: boolean;
  createdAt: string;
  updatedAt: string;
  members: ChannelMember[];
  messages: ChannelMessageSummary[];
}

export interface ChannelMessageSummary {
  messageId: string;
  clientMessageId: string;
  body: string;
  state: DeliveryState | null;
  createdAt: string;
  bodySha256: string;
  codexThreadId: string | null;
  codexTurnId: string | null;
  authorKind: "user" | "coordinator" | "member" | "automation";
  authorBotId: string | null;
  authorBotName: string | null;
  phase: "user" | "routing" | "worker" | "synthesis" | "direct";
  presentationKind: "message" | "status";
  outcome: "completed" | "failed" | "timed_out" | "interrupted" | null;
  retryable: boolean;
}

export interface CreateChannelRequest {
  clientRequestId?: string;
  name: string;
  description?: string;
  coordinatorBotId: string;
  memberBotIds?: string[];
}

export interface UpdateChannelRequest {
  name?: string;
  description?: string | null;
  isArchived?: boolean;
}

export interface AddChannelMemberRequest {
  botId: string;
  role?: "worker";
}

export type ChannelListResponse = ChannelSummary[];

export interface ConversationFile {
  id: string;
  kind: ConversationFileKind;
  name: string;
  mimeType: string | null;
  byteSize: number | null;
  sha256: string | null;
  relativePath: string | null;
  state: string;
  additions: number | null;
  deletions: number | null;
  createdAt: string;
  updatedAt: string;
}

export type ConversationFileKind = "attachment" | "file_change" | "artifact";

/** JSON carried in an activity event with category "artifact". */
export interface ArtifactEventDetail {
  artifactId: string;
  name: string;
  mimeType: "application/pdf" | "text/markdown" | "image/png";
  byteSize: number;
  sha256: string;
  relativePath: string;
}

export interface CreateConversationFileRequest {
  name: string;
  mimeType?: string;
  contentBase64: string;
}

export interface ConversationMessage {
  messageId: string;
  clientMessageId: string;
  body: string;
  state: DeliveryState;
  createdAt: string;
  bodySha256: string;
  codexThreadId: string | null;
  codexTurnId: string | null;
  attachmentIds: string[];
}

export interface ConversationAssistantMessage {
  messageId: string;
  codexThreadId: string;
  codexTurnId: string;
  itemId: string;
  text: string;
  state: "streaming" | "completed";
  createdAt: string;
  updatedAt: string;
}

export type ConversationThreadItemType =
  | "userMessage"
  | "hookPrompt"
  | "agentMessage"
  | "functionCallOutput"
  | "reasoning"
  | "commandExecution"
  | "fileChange"
  | "mcpToolCall"
  | "dynamicToolCall"
  | "subAgentActivity"
  | "webSearch"
  | "plan"
  | "imageView"
  | "imageGeneration"
  | "sleep"
  | "enteredReviewMode"
  | "exitedReviewMode"
  | "collabAgentToolCall"
  | "contextCompaction"
  | "approval"
  | "error"
  | "unknown";

export type ConversationThreadItemState = "started" | "streaming" | "completed" | "failed" | "interrupted" | "waiting" | "unknown";

export interface ConversationThreadItemBase<T extends ConversationThreadItemType, P = unknown> {
  id: string;
  type: T;
  state: ConversationThreadItemState;
  text: string | null;
  payload: P;
  createdAt: string;
  updatedAt: string;
}

export interface ConversationCommandExecutionPayload {
  command?: string | null;
  cwd?: string | null;
  output?: string | null;
  exitCode?: number | null;
  durationMs?: number | null;
  action?: string | null;
}

export interface ConversationFileChangePayload {
  paths?: string[];
  additions?: number | null;
  deletions?: number | null;
  status?: string | null;
  detail?: string | null;
}

export interface ConversationToolCallPayload {
  server?: string | null;
  tool?: string | null;
  status?: string | null;
  error?: string | null;
  durationMs?: number | null;
  arguments?: unknown;
  result?: unknown;
}

export interface ConversationHookPromptPayload {
  fragments?: unknown[];
}

export interface ConversationFunctionCallOutputPayload {
  name?: string | null;
  namespace?: string | null;
  output?: unknown;
}

export interface ConversationDynamicToolCallPayload {
  namespace?: string | null;
  tool?: string | null;
  arguments?: unknown;
  contentItems?: unknown[] | null;
  success?: boolean | null;
}

export interface ConversationSubAgentActivityPayload {
  kind?: string | null;
  agentThreadId?: string | null;
  agentPath?: string | null;
  agentNickname?: string | null;
  agentRole?: string | null;
  status?: string | null;
}

export interface ConversationCollabAgentToolCallPayload {
  receiverThreadIds?: string[] | null;
  senderThreadId?: string | null;
  agentsStates?: Record<string, unknown> | null;
  tool?: string | null;
  status?: string | null;
}

export interface ConversationSleepPayload {
  durationMs?: number | null;
}

export interface ConversationReviewPayload {
  review?: string | null;
}

export interface ConversationSearchPayload {
  query?: string | null;
  resultCount?: number | null;
  durationMs?: number | null;
}

export interface ConversationImagePayload {
  imageUrl?: string | null;
  alt?: string | null;
  mediaType?: string | null;
}

export interface ConversationCompactionPayload {
  summary?: string | null;
  compactedAt?: string | null;
}

export type ConversationThreadItem =
  | ConversationThreadItemBase<"userMessage", { clientId?: string | null; attachments?: string[] }>
  | ConversationThreadItemBase<"hookPrompt", ConversationHookPromptPayload>
  | ConversationThreadItemBase<"agentMessage", { phase?: string | null; memoryCitation?: unknown }>
  | ConversationThreadItemBase<"functionCallOutput", ConversationFunctionCallOutputPayload>
  | ConversationThreadItemBase<"reasoning">
  | ConversationThreadItemBase<"commandExecution", ConversationCommandExecutionPayload>
  | ConversationThreadItemBase<"fileChange", ConversationFileChangePayload>
  | ConversationThreadItemBase<"mcpToolCall", ConversationToolCallPayload>
  | ConversationThreadItemBase<"dynamicToolCall", ConversationDynamicToolCallPayload>
  | ConversationThreadItemBase<"subAgentActivity", ConversationSubAgentActivityPayload>
  | ConversationThreadItemBase<"webSearch", ConversationSearchPayload>
  | ConversationThreadItemBase<"plan">
  | ConversationThreadItemBase<"imageView", ConversationImagePayload>
  | ConversationThreadItemBase<"imageGeneration", ConversationImagePayload>
  | ConversationThreadItemBase<"sleep", ConversationSleepPayload>
  | ConversationThreadItemBase<"enteredReviewMode", ConversationReviewPayload>
  | ConversationThreadItemBase<"exitedReviewMode", ConversationReviewPayload>
  | ConversationThreadItemBase<"collabAgentToolCall", ConversationCollabAgentToolCallPayload>
  | ConversationThreadItemBase<"contextCompaction", ConversationCompactionPayload>
  | ConversationThreadItemBase<"approval">
  | ConversationThreadItemBase<"error">
  | ConversationThreadItemBase<"unknown", { originalType?: string | null; raw?: unknown }>;

export interface ConversationTurn {
  id: string;
  status: "inProgress" | "completed" | "failed" | "interrupted" | "unknown";
  createdAt: string;
  updatedAt: string;
  items: ConversationThreadItem[];
}

export interface ConversationThreadProjection {
  threadId: string | null;
  turns: ConversationTurn[];
  /** Opaque conversation-scoped cursor. Pass as before to load older entries. */
  nextCursor: string | null;
  /** False for local history pages; consult history/refresh for refresh status. */
  hydrated: boolean;
}

export interface SubagentSummary {
  conversationId: string;
  threadId: string;
  parentConversationId: string;
  parentThreadId: string;
  title: string;
  agentNickname: string | null;
  agentRole: string | null;
  agentPath: string | null;
  status: string;
  canAcceptDirectInput: boolean | null;
  isArchived: boolean;
}

export interface SubagentListResponse {
  available: boolean;
  detail: string | null;
  subagents: SubagentSummary[];
}

export type WorkspaceRootKind =
  | "botWorkspace"
  | "workingDirectory"
  | "groupWorkspace"
  | "childWorkingDirectory"
  | "appliedGrant";

export interface WorkspaceRoot {
  id: string;
  label: string;
  path: string;
  isDirectory: boolean;
  kind: WorkspaceRootKind;
  readOnly: true;
}

export interface WorkspaceRootsResponse {
  available: boolean;
  detail: string | null;
  roots: WorkspaceRoot[];
  attachments: ConversationFile[];
}

export interface WorkspaceEntry {
  name: string;
  path: string;
  isDirectory: boolean;
  byteSize?: number | null;
  mimeType?: string | null;
}

export interface WorkspaceDirectoryResponse {
  rootId: string;
  path: string;
  parentPath: string | null;
  entries: WorkspaceEntry[];
  nextOffset: number | null;
}

export type WorkspaceGitChangeState =
  | "staged"
  | "unstaged"
  | "untracked"
  | "renamed"
  | "deleted"
  | "conflicted"
  | "modified";

export interface WorkspaceGitChange {
  path: string;
  originalPath: string | null;
  state: WorkspaceGitChangeState;
  indexStatus: string;
  worktreeStatus: string;
}

export interface WorkspaceGitStatusResponse {
  available: boolean;
  detail: string | null;
  repositoryPath: string | null;
  changes: WorkspaceGitChange[];
}

export interface WorkspaceDiffResponse {
  path: string;
  staged: boolean;
  diff: string;
}

export type ComputerSessionState =
  | "preparing"
  | "awaitingSource"
  | "live"
  | "paused"
  | "stale"
  | "ended"
  | "failed"
  | "unavailable";

export interface ComputerCapability {
  available: boolean;
  action: "update-host" | "retry" | "none";
  reason: string;
}

export interface ComputerControlCapability {
  available: boolean;
  action: "update-host" | "retry" | "none";
  reason: string;
  heartbeatIntervalSeconds: 3;
  leaseExpirySeconds: 10;
}

export interface ComputerSource {
  id: string | null;
  name: string | null;
  kind: string | null;
  width: number | null;
  height: number | null;
  scale: number | null;
  crop: ComputerCrop | null;
}

export interface ComputerCrop {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface StartComputerSessionRequest {
  clientRequestId: string;
  conversationId: string;
  hostInstallationId: string;
  generation?: 1;
  source?: ComputerSource;
}

export interface ComputerSession {
  id: string;
  clientRequestId: string;
  ownerDeviceId: string;
  hostInstallationId: string;
  conversationId: string;
  generation: number;
  state: ComputerSessionState;
  source: ComputerSource;
  geometryRevision: number;
  failureReason: string | null;
  createdAt: string;
  updatedAt: string;
  lastStateAt: string;
  endedAt: string | null;
  capability: ComputerCapability;
  control: ComputerControlCapability;
}

export interface ComputerAdmissionRequest {
  generation: number;
  role: "viewer" | "publisher";
}

export interface ComputerAdmissionResponse {
  session: ComputerSession;
  role: "viewer" | "publisher";
  granted: boolean;
  admission: Record<string, unknown> | null;
  capability: ComputerCapability;
}

export interface AcquireComputerControlRequest {
  clientRequestId: string;
  generation: number;
  geometryRevision: number;
  sourceId: string | null;
}

export interface ComputerControlBindingRequest {
  leaseId: string;
  generation: number;
  geometryRevision: number;
  sourceId: string | null;
}

export type ComputerInputAction =
  | { type: "pointer"; x: number; y: number; phase: "move" | "down" | "up"; button?: "left" | "right" | "middle" | null }
  | { type: "scroll"; deltaX: number; deltaY: number }
  | { type: "key"; key: string; phase: "down" | "up" | "press"; modifiers: number }
  | { type: "text"; text: string }
  | { type: "clipboard"; operation: "copyToPhone" }
  | { type: "clipboard"; operation: "pasteFromPhone"; text: string }
  | { type: "releaseAll" };

export interface ComputerInputBatchRequest extends ComputerControlBindingRequest {
  sequence: number;
  actions: ComputerInputAction[];
}

export interface ComputerControlLease {
  id: string;
  sessionId: string;
  ownerDeviceId: string;
  hostInstallationId: string;
  conversationId: string;
  generation: number;
  sourceId: string | null;
  geometryRevision: number;
  status: "active" | "released" | "expired";
  lastSequence: number;
  acquiredAt: string;
  updatedAt: string;
  expiresAt: string;
  releasedAt: string | null;
}

export interface ComputerControlActionResponse {
  granted: boolean;
  acknowledged: boolean;
  status: "active" | "busy" | "unavailable" | "stale" | "expired" | "released" | "rejected" | "unsupported";
  reason: string;
  lease: ComputerControlLease | null;
  control: ComputerControlCapability;
  clipboardText?: string;
}

export interface TeachingCapability {
  available: boolean;
  action: "update-host" | "retry" | "none";
  reason: string;
  provider: string;
  maxDurationSeconds: number;
  maxEvents: number;
  maxEvidenceBytes: number;
}

export type TeachingSessionState =
  | "draft"
  | "awaitingCaptureConsent"
  | "starting"
  | "recording"
  | "reviewing"
  | "skillDraft"
  | "approvedVersion"
  | "testing"
  | "replayVerified"
  | "testFailed"
  | "cancelled"
  | "interrupted"
  | "expired"
  | "unavailable";

export interface StartTeachingSessionRequest {
  clientRequestId: string;
  conversationId: string;
  computerSessionId: string;
  controlLeaseId: string;
  captureScope: "authenticated-remote-control";
  outcome: string;
}

export type TeachingEventKind = "pointer" | "scroll" | "key" | "text" | "clipboard";

export interface TeachingEvent {
  sequence: number;
  actionIndex: number;
  kind: TeachingEventKind;
  payload: Record<string, unknown>;
  createdAt: string;
}

export interface TeachingSession {
  id: string;
  clientRequestId: string;
  ownerDeviceId: string;
  hostInstallationId: string;
  botId: string;
  conversationId: string;
  computerSessionId: string | null;
  controlLeaseId: string | null;
  state: TeachingSessionState;
  captureScope: string;
  captureProvider: string;
  outcome: string;
  name: string | null;
  description: string | null;
  goal: string | null;
  inputSchema: Record<string, unknown> | null;
  prerequisites: string | null;
  steps: string | null;
  resultChecks: string | null;
  failureReason: string | null;
  revision: number;
  eventCount: number;
  evidenceBytes: number;
  contentHash: string | null;
  createdAt: string;
  updatedAt: string;
  startedAt: string | null;
  endedAt: string | null;
  expiresAt: string | null;
  events: TeachingEvent[];
  capability: TeachingCapability;
}

export interface TeachingRevisionRequest { expectedRevision: number }
export interface OptionalTeachingRevisionRequest { expectedRevision?: number | null }

export interface ReviewTeachingSessionRequest {
  expectedRevision: number;
  name: string;
  description: string;
  goal: string;
  inputSchema: Record<string, unknown>;
  prerequisites: string;
  steps: string;
  resultChecks: string;
}

export interface SaveBotSkillVersionRequest {
  clientRequestId: string;
  expectedRevision: number;
  slug?: string | null;
}

export interface BotSkillVersion {
  id: string;
  version: number;
  sourceSessionId: string;
  contentHash: string;
  inputSchema: Record<string, unknown>;
  verificationState: "unverified" | "structurallyVerified" | "fixtureVerified" | "replayVerified" | "testFailed";
  createdAt: string;
}

export interface BotSkill {
  id: string;
  botId: string;
  slug: string;
  name: string;
  description: string;
  state: "draft" | "active" | "archived";
  activeVersion: number | null;
  discoverability: "bot-private";
  versions: BotSkillVersion[] | null;
}

export interface BotSkillListResponse {
  capability: TeachingCapability;
  skills: BotSkill[];
}

export interface SaveBotSkillVersionResponse {
  skill: BotSkill;
  version: BotSkillVersion;
  teachingSession: TeachingSession;
}

export interface RunBotSkillFixtureTestRequest {
  clientRequestId: string;
  contentHash: string;
  inputSchema: Record<string, unknown>;
  inputs: Record<string, unknown>;
  workingDirectory?: string | null;
}

export interface BotSkillFixtureTestReceipt {
  id: string;
  clientRequestId: string;
  ownerDeviceId: string;
  botId: string;
  skillId: string;
  version: number;
  contentHash: string;
  inputSchemaHash: string;
  inputSchema: Record<string, unknown>;
  inputs: Record<string, unknown>;
  workingDirectory: string;
  provider: "deterministic-local";
  executionKind: "deterministicFixture";
  status: "succeeded" | "failed";
  verificationState: "fixtureVerified" | "testFailed";
  artifactPath: string | null;
  artifactHash: string | null;
  artifactBytes: number;
  evidence: Record<string, unknown>;
  failureReason: string | null;
  createdAt: string;
  completedAt: string;
}

/** The loss-minimized event carried in the legacy activity envelope while
 * older clients still consume WonderEvent. */
export interface ConversationThreadItemUpsertEvent {
  type: "thread_item_upsert";
  data: ConversationThreadItem;
}

export interface ConversationSnapshot {
  initialization?: { questionId: string | null } | null;
  conversationId: string;
  /** Committed host journal boundary; absent on pre-D4 hosts. Scope is this conversation only. */
  hostEpoch?: string;
  lastSequence?: number;
  codexThreadId: string | null;
  messages: ConversationMessage[];
  assistantMessages: ConversationAssistantMessage[];
  /** New typed history projection; omitted by older Wonder hosts during migration. */
  thread?: ConversationThreadProjection;
  events: Array<{
    eventId: string;
    hostEpoch: string;
    sequence: number;
    occurredAt: string;
    requestId?: string | null;
    deviceId?: string | null;
    conversationId?: string | null;
    messageId?: string | null;
    threadId?: string | null;
    turnId?: string | null;
    itemId?: string | null;
    approvalId?: string | null;
    event: { type: string; data?: unknown };
  }>;
}

export interface SteerTurnRequest {
  deviceId: string;
  clientMessageId: string;
  body: string;
  expectedTurnId: string;
  attachmentIds?: string[];
}

export interface SendMessageRequest {
  deviceId: string;
  clientMessageId: string;
  body: string;
  attachmentIds?: string[];
}

export interface CreateConversationRequest {
  botId: string;
  title?: string;
}

export interface UpdateConversationRequest {
  title?: string;
  isArchived?: boolean;
  isPinned?: boolean;
  markRead?: boolean;
}

export type SteerTurnResponse = ClientMessageReceipt;

export interface ClientMessageReceipt {
  clientMessageId: string;
  wonderMessageId: string;
  bodySha256: string;
  conversationId: string;
  deliveryState: DeliveryState;
  codexThreadId: string | null;
  codexTurnId: string | null;
}

export type AsrErrorCategory =
  | "microphone_permission" | "unsupported_recording_format" | "no_audio" | "too_short"
  | "upload" | "decoder" | "model_unavailable" | "timeout" | "transcription" | "busy" | "rate_limited" | "interrupted" | "cancelled" | "unsupported_language";

export interface AsrTranscription {
  modelId: string;
  language: "auto";
  processingSource: "paired_mac";
  id: string;
  state: "queued" | "processing" | "completed" | "failed" | "cancelled";
  sourceDeviceId: string;
  durationMs: number;
  transcriptText: string | null;
  wordTimestamps: Array<{ word: string; startMs: number; endMs: number; confidence?: number | null }> | null;
  confidence: number | null;
  retryExpiresAtMs: number | null;
  errorCategory: AsrErrorCategory | null;
}

/** GET/POST /api/v1/conversations/{id}/history/refresh. A 202 response
 * acknowledges the refresh job, not completed runtime hydration. */
export interface HistoryRefreshStatus {
  state: "idle" | "refreshing" | "completed" | "failed";
  detail: string | null;
}
export interface HistoryQuery {
  before?: string;
  /** 1..100, default 100. */
  limit?: number;
}
