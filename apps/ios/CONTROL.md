# Driving Wonder Testing from the command line

`scripts/wonderctl` lets an agent launch Wonder Testing in a dedicated simulator,
jump to a known state with Diagnostics fixtures, tap and type by accessibility
identifier, and capture evidence. A step takes well under a second and needs no
screenshot model, and a scenario file reruns the same way every time.

Use it to prove iOS behavior. Use computer use or screenshots only for visual
judgment and for flows that no scenario covers yet.

## Where it runs

Run `wonderctl` on this Mac's simulators while developing; with no `--host` it
builds into `.local/build/control-sim` and drives local simulators. CI runs the
feature map on the Mac mini, whose simulators belong to the CI runners, so reach
for `--host` only to reproduce a CI-only failure there.

Pass `--host mac-mini`, or export `WONDER_CONTROL_HOST=mac-mini`, to run every
command on the Mac mini instead of this Mac. On the mini itself, which has
`~/.config/wonder/is-build-host`, `--host` is ignored and commands run locally. `build`, `run` and `sync` first copy
the working tree there, including uncommitted and untracked files but not ignored
ones. Each local checkout or worktree gets its own copy under `~/wonder-control/`
on the mini. Evidence is copied back to `.local/control/` after every command.

```sh
scripts/wonderctl doctor
scripts/wonderctl build
scripts/wonderctl run apps/ios/control/scenarios/automations-create.wctl
scripts/wonderctl --device duo run apps/ios/control/scenarios/automations-create.wctl
```

A scenario failure exits nonzero and saves a screenshot of the failing step. Under CI (`CI` set) every
`--timeout` is multiplied by 3, because a loaded runner can spend several seconds on
one tap; set `WONDER_CONTROL_TIMEOUT_SCALE` to override. Waits return as soon as they
succeed, so only failures take longer. A state that shows only briefly needs a
fixture that holds it, not a longer wait.

`wait`, `tap`, `hold` and `back` only count elements whose frame overlaps the screen.
Views SwiftUI keeps off screen stay in the accessibility tree: the closed sidebar's
rows sit at negative x. Matching them let `wait` pass and `tap` report success
while nothing happened, so a slow first tap failed several steps later instead.

If a freshly created simulator renders only black (the accessibility tree still
answers), shut it down and `xcrun simctl erase` it, then run `scripts/wonderctl
--device NAME device` and `install` again. This happened once to a new Duo on iOS
27.1; reinstalling the runtime was not needed.

## Xcode and simulators

`wonderctl` builds with `~/Applications/Xcode.app` when it exists (currently Xcode
27.1, which adds the iPhone Duo) and otherwise with the selected Xcode. Release
uploads keep using `/Applications/Xcode.app` through fastlane.

Each `--device` profile owns one simulator, and CI runs the feature map on all three:

| Profile | Simulator | Runtime |
| --- | --- | --- |
| `iphone` (default) | `Wonder Control iPhone` | newest installed iOS 26 (26.2 on the Mac mini) |
| `iphone-27` | `Wonder Control iPhone 27` | newest iOS 27 that runs an iPhone (27.0; 27.1 is Duo-only) |
| `duo` | `Wonder Control iPhone Duo` | newest runtime with the Duo (27.1) |

A profile's simulator is created on its runtime. A same-named simulator on another
runtime is deleted and replaced, and a missing runtime is an error that says how to
install it. Other simulators are never booted, erased or shut down. `device`
waits for accessibility automation after a boot, which can take about 30 seconds
on the Duo. `build`, `run`, `device` and `install` take a per-simulator lock on
that Mac, so agents from different checkouts cannot drive the same simulator at
once; the second one exits with status 75 and should wait and retry.

The iPhone Duo runs Wonder on its unfolded display. Fold posture is only available
from Simulator's Device Hub, so check folding by hand. Most app extensions do not
run on the Duo simulator. Do not change a Duo's display power with
`simctl io screenConfig`: it moves the primary display. `simctl erase` does not
restore it (measured: an erased Duo kept a second display and dead input), so
`device --recreate` deletes the Duo and creates it again, and `device --erase` does
the same on the Duo profile.

## Commands

| Command | Effect |
| --- | --- |
| `doctor` | Reports Xcode, AXe, the simulator, the build and other booted simulators. |
| `device [--erase] [--recreate] [--shutdown]` | Creates and boots the simulator. `--erase` gives a fresh install; `--recreate` deletes and creates it again (what `--erase` does on the Duo). |
| `build [--no-install]` | Builds `WonderTesting` in `TestingDiagnostics` and installs it. |
| `launch --fixture NAME …` | Relaunches the app with launch flags. `fixtures` lists them. |
| `open URL` | Opens a deep link. |
| `tap --id ID [--type Button] [--nth N]` / `--label TEXT` / `--xy X,Y` | Waits for an on-screen match and taps its centre. `--type` and `--nth` pick one of several matches. |
| `hold --id ID` / `--label` / `--contains TEXT` `[--nth N] [--seconds S]` | Long-presses an element, to open a context menu. Holds the touch inside one `axe batch` session, because `axe touch --down --up` fails on the iPhone Duo ("could not establish simulator input"). |
| `clipboard --clear` / `--contains TEXT` / `--not-contains TEXT` / `--show` | Clears or asserts on the simulator pasteboard, so Copy actions are checked by their result. |
| `type TEXT`, `swipe up\|down\|left\|right [--in ID]`, `button home` | Input. `--in` drags inside one element, such as a list in a short panel on the Duo. |
| `back` | Taps the navigation back control; it is a Button on the iPhone and another element type on the Duo. |
| `wait --id ID` / `--label` / `--contains TEXT` `[--gone]` | Polls the accessibility tree for an element on screen. This is the assertion. `--never S` instead fails if the element shows at any check during S seconds, for a state that must not flicker. |
| `order --ids A,B,C` | Asserts the elements with these accessibility ids appear top to bottom in this order. |
| `tree [--json]` | Prints the accessibility tree: type, identifier, label, value, frame. |
| `shot NAME` | Saves a PNG under `.local/control/evidence/`. |
| `container`, `logs` | App data container path and recent app logs, for checking stored state. |
| `run FILE` | Runs a scenario: one command per line, `#` comments, stops at the first failure. |

## Feature map

Scenarios live in [control/scenarios](control/scenarios). Each one names the
feature it proves, starts from a fixture, and ends with a `wait` on the resulting
state and a `shot`. When you change a feature that has a scenario, run it on both
devices. When you add user-visible behavior, add or extend a scenario using stable
accessibility identifiers. Assert on text you typed, not on cursor position or the
fixture's prefilled content.

| Feature | Scenario | Fixture |
| --- | --- | --- |
| First launch with nothing paired: New Chat explains Wonder needs the Wonder Mac app, offers Add computer and the Mac download with no Settings sheet over it; the empty Chats list offers Add computer; on Dracula the filled Add computer keeps a readable label (check the shot) | `first-launch.wctl` | `-diagnostics-unpaired` |
| Project schedules | `automations-create.wctl` | `-diagnostics-automations-fixture` |
| Settings > computer > Providers: Codex and Claude as the Mac's Providers page words them (plan, version, update waiting); Update now / Reconnect drives the Mac's Reconnect with progress and result; no sign-out; refused with an explanation while an agent works | `mac-providers.wctl`, `mac-providers-working.wctl` | `-diagnostics-project-actions` (with `-diagnostics-providers-working`) and the subagent and chat-layout fixtures |
| Automations open from each computer's section of the sidebar (no longer in its connection settings) | `sidebar-automations.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Add project from the sidebar is one sheet: New folder (created on the Mac, named after the project; a taken name refused in the Mac's words), Existing folder, and Add beside folders Codex or Claude Code use | `add-project.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Files and document preview | `workspace-readme.wctl` | `-files-preview`, `-project-files-conversation-preview` |
| Composer draft | `composer-draft.wctl` | `-send-preview`, `-project-files-conversation-preview` |
| Claude access menu in order Auto, Ask, Accept edits, Plan, Full access; Plan shows only on the shield, not as a chip; the title menu shows 5-hour and weekly use, nothing beside New chat, no provider icon | `claude-access-picker.wctl` | `-diagnostics-project-read` and `-diagnostics-usage-fixture` with the subagent and chat-layout fixtures |
| Codex usage sits in the title menu, one entry per window Codex reports, named by its length; a weekly-only (Pro) plan shows Weekly alone; no usage entry when it can't be read | `codex-header-usage.wctl`, `codex-usage-weekly-only.wctl`, `codex-header-usage-unavailable.wctl` | `-diagnostics-project-actions` with `-diagnostics-usage-fixture` (and `-diagnostics-usage-weekly-only`) or `-diagnostics-usage-unavailable` |
| A provider that didn't answer the Mac's thread list explains why in the sidebar and offers Retry | `sidebar-threads-retry.wctl` | `-diagnostics-project-actions` with `-diagnostics-project-threads-partial` |
| Permission and question pill replacing the conversation | `approval-dock.wctl` | `-phone-approval-preview command` arriving via `-attention-arrives-preview`; `-question-preview` |
| Host default model, resolved effort and Speed in New Chat and a Project thread | `agent-defaults.wctl` | `-diagnostics-project-speed` with the subagent and chat-layout fixtures |
| Settings Default models (app-wide): Codex and Claude pickers, a saved choice, and Try again after a failed load | `default-models.wctl` | `-diagnostics-default-models` and `-diagnostics-default-models-fail-once` with the subagent and chat-layout fixtures |
| Computer view uses the theme background, like its Take control area (swept per theme) | `computer-view-theme.wctl` | `-diagnostics-computer-session-fixture` with `-diagnostics-theme` |
| Copy a message from a bubble's long-press menu | `copy-message.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Copy a chat as Markdown from the header menu | `copy-markdown.wctl` | `-read-preview`, `-send-preview`, `-project-files-conversation-preview` |
| Copy a thread's Codex thread ID or Claude session ID from its sidebar long-press menu; copy a Project's folder path from the Project's | `copy-thread-id.wctl` | `-diagnostics-project-actions` with `-diagnostics-sidebar-status` |
| Long sidebar thread titles end before the working spinner and unread dot (check the shot on `iphone`) | `sidebar-thread-status.wctl` | `-diagnostics-project-actions` with `-diagnostics-sidebar-status` |
| Archive a Codex thread (in Codex) or a Claude Code thread (in Wonder) from its long-press menu; the Project's Archived threads lists it and Restore brings it back | `archive-thread.wctl`, `archive-claude-thread.wctl` | `-diagnostics-project-actions`; `-diagnostics-project-read` |
| Files keeps the Edited files pill; the open composer pill shows a selected state (check the shots) | `composer-pills.wctl` | `-read-preview`, `-send-preview`, `-activity-preview`, `-response-turn-diff-preview` with the Files fixtures |
| Fork a started, idle Project thread from the header or an agent reply, opening the "(fork)" thread | `fork-thread.wctl` | `-diagnostics-project-actions` |
| A refused fork shows a plain notice; an unstarted thread offers no Fork | `fork-refused.wctl` | `-diagnostics-project-actions` with `-diagnostics-project-fork-conflict`; `-diagnostics-project-speed` |
| A Codex reply's edited-files pill counts the whole-turn diff, including a file written from the shell | `edited-files-turn-diff.wctl` | `-read-preview`, `-send-preview`, `-activity-preview` with `-response-turn-diff-preview` |
| A Claude agent task's commands, edits and a still-running tool; each tool call starts collapsed and opens and closes on tap; the group header hides and shows its calls | `claude-agent-transcript.wctl` | `-diagnostics-project-subagents` with `-diagnostics-project-claude-tasks` |
| Claude agent tasks grouped Running then Completed with status glyphs (status words only for VoiceOver) and no avatars, "N running" on the pill counting agents, background commands, monitors and linked sessions as Claude does (a linked session runs on the Mac, no Stop), and Stop with a confirmation ending as Stopped | `claude-agent-tasks.wctl` | `-diagnostics-project-subagents` with `-diagnostics-project-claude-tasks` |
| A refused Stop explains why and leaves the task running | `claude-agent-task-stop-refused.wctl` | the same with `-diagnostics-project-claude-stop-fails` |
| Claude on the Mac finished its reply but still runs agent tasks in its own process: the chat is not shown working, and the composer says sending stops those tasks | `claude-tasks-on-mac.wctl` | `-read-preview`, `-send-preview`, `-project-files-conversation-preview`, `-project-tasks-on-mac-preview` |
| Send or queue is decided when a message is sent and its first placement is final: with nothing running it shows in the conversation and never as Queued (before the Mac's receipt, while dispatch has not started it, after a stopped reply, and when reopened); while a reply runs it shows as Queued from the first frame and the button says Queue; a second message behind the first's reply queues | `send-direct.wctl`, `send-after-stop.wctl`, `send-queued.wctl`, `send-mixed.wctl` | `-diagnostics-send-states` (with `-diagnostics-send-stopped` or `-diagnostics-send-running`) and the subagent and chat-layout fixtures; `-diagnostics-send-legacy-queue` reproduces an older Mac whose queue listed an unstarted direct send |
| Guide in a Project Codex thread: while a reply runs, touching and holding send offers Guide (steer the running reply) beside Queue | `guide-project.wctl` | `-diagnostics-send-states` with `-diagnostics-send-running` and the subagent and chat-layout fixtures |
| A desktop paste shows its pasted text, not `pasted_content` tags | `desktop-paste.wctl` | `-diagnostics-project-actions` |
| An image attached to a prompt in Claude Code on the Mac shows, loaded, on the user's bubble | `desktop-image.wctl` | `-diagnostics-project-actions` |
| A `!` shell command and a slash command from Claude Code show as command cards (output and errors collapsible, errors marked), not `bash-input` or `command-name` tags | `claude-command-blocks.wctl` | `-diagnostics-project-actions` with `-diagnostics-project-command-blocks` |
| A bubble's long-press menu lifts only the bubble, not a wider row-sized panel (check the shots; sweep themes and appearances) | `message-menu-preview.wctl` via `control/theme-sweep.sh --scenario message-menu-preview DEVICE -- IDS` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures and `-diagnostics-theme ID` |
| Select text from a bubble's menu opens the whole message in a selectable sheet | `copy-message.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Forced themes: themed sidebar, chat, composer and coloured code; the Settings theme picker | `theme-appearance.wctl` via `control/theme-sweep.sh DEVICE [light\|dark] -- IDS` | `-diagnostics-project-actions` with `-diagnostics-theme ID` |
| Forced themes on New Chat and its model sheet, Files, Markdown Preview, Source and the expanded viewer, JSON Formatted and Raw, JSON Lines and a text file (`scripts/check-theme` guards the code) | `theme-surfaces.wctl` via `control/theme-sweep.sh --scenario theme-surfaces DEVICE -- IDS` | `-diagnostics-project-speed`; `-workspace-viewer-preview` with the Files fixtures, both with `-diagnostics-theme ID` |
| Message and code fonts on bubbles, a code block, the composer, Markdown Preview and Source and JSON | `font-appearance.wctl` via `control/theme-sweep.sh --scenario font-appearance DEVICE -- MESSAGE+CODE...` | `-diagnostics-project-actions`; `-workspace-viewer-preview` with the Files fixtures, both with `-diagnostics-font MESSAGE+CODE` |
| Settings Font picker: a message and a code font kept across a relaunch; a bundled font's license from its long-press menu; every license under Settings Acknowledgements | `font-picker.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Markdown file Preview or Source, remembered across a relaunch | `markdown-viewer.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| A project README's relative image shows from the workspace; a missing or outside-the-project image says so in place; a relative `.md` link opens in the viewer | `markdown-local-references.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| JSON Formatted or Raw, Copy of the shown form, an invalid file, JSON Lines records | `json-viewer.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| Project composer lists Codex and Claude models by provider with a footnote; an other-provider pick shows in the composer with no dialog and the next message carries `projectModel`; the timeline shows "Switched to ..."; a same-provider pick is saved | `provider-switch.wctl` | `-diagnostics-project-provider-switch` with the subagent and chat-layout fixtures |
| A message another thread wrote shows "From <thread>"; "Agent tasks finished: ..." is a compact row | `agent-thread-messages.wctl` | `-diagnostics-project-provider-switch` with the subagent and chat-layout fixtures |
| A Project thread's pull requests: GitHub pill with count and check state, a sheet listing state and checks, a failed refresh that keeps the list | `pull-requests.wctl` | `-diagnostics-project-pull-requests` (and `-refresh-fails`) with the subagent and chat-layout fixtures |
| No pull request pill when the Mac's GitHub CLI is signed out | `pull-requests-hidden.wctl` | the same with `-diagnostics-project-pull-requests-signed-out` |
| A Project thread's branch pill (branch name, tree for a worktree, uncommitted +/−) opens Changes: Uncommitted and Branch (`branch → base`, ahead/behind) list files with status and +/−, a file opens its diff, a binary or over-limit file explains itself, Last response reuses the edited-files review | `branch-changes.wctl` | `-read-preview`, `-send-preview`, `-activity-preview`, `-response-turn-diff-preview`, `-project-files-conversation-preview` with `-project-git-preview` |
| No branch pill when the thread's folder is not in a Git repository | `branch-changes-hidden.wctl` | the same with `-project-git-not-repository-preview` |
| Model sheet header stays pinned: Done is reachable after scrolling in New Chat and a Project thread (check on the Duo) | `agent-defaults.wctl` | `-diagnostics-project-speed` with the subagent and chat-layout fixtures |

Fixtures cover app behavior without a paired Mac. Pairing, Tailscale and live
model work still need the live tests in [TESTING.md](TESTING.md).
