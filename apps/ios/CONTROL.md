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

`--device iphone` (default) and `--device duo` each own one simulator, `Wonder
Control iPhone` and `Wonder Control iPhone Duo`, created on the newest installed
iOS runtime. Other simulators are never booted, erased or shut down. `device`
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
| `wait --id ID` / `--label` / `--contains TEXT` `[--gone]` | Polls the accessibility tree for an element on screen. This is the assertion. |
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
| Project schedules | `automations-create.wctl` | `-diagnostics-automations-fixture` |
| Files and document preview | `workspace-readme.wctl` | `-files-preview`, `-project-files-conversation-preview` |
| Composer draft | `composer-draft.wctl` | `-send-preview`, `-project-files-conversation-preview` |
| Claude access menu in order Auto, Ask, Accept edits, Plan, Full access; Plan shows only on the shield, not as a chip; header shows 5-hour and weekly use, no provider icon or usage menu entry | `claude-access-picker.wctl` | `-diagnostics-project-read` and `-diagnostics-usage-fixture` with the subagent and chat-layout fixtures |
| Codex header shows primary (5-hour) and secondary (weekly) use; no pill when usage can't be read | `codex-header-usage.wctl`, `codex-header-usage-unavailable.wctl` | `-diagnostics-project-actions` with `-diagnostics-usage-fixture` or `-diagnostics-usage-unavailable` |
| A provider that didn't answer the Mac's thread list explains why in the sidebar and offers Retry | `sidebar-threads-retry.wctl` | `-diagnostics-project-actions` with `-diagnostics-project-threads-partial` |
| Permission and question pill replacing the conversation | `approval-dock.wctl` | `-phone-approval-preview command` arriving via `-attention-arrives-preview`; `-question-preview` |
| Host default model, resolved effort and Speed in New Chat and a Project thread | `agent-defaults.wctl` | `-diagnostics-project-speed` with the subagent and chat-layout fixtures |
| Settings Default models (app-wide): Codex and Claude pickers, a saved choice, and Try again after a failed load | `default-models.wctl` | `-diagnostics-default-models` and `-diagnostics-default-models-fail-once` with the subagent and chat-layout fixtures |
| Computer view uses the theme background, like its Take control area (swept per theme) | `computer-view-theme.wctl` | `-diagnostics-computer-session-fixture` with `-diagnostics-theme` |
| Copy a message from a bubble's long-press menu | `copy-message.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Copy a chat as Markdown from the header menu | `copy-markdown.wctl` | `-read-preview`, `-send-preview`, `-project-files-conversation-preview` |
| Copy a thread's folder path from its sidebar long-press menu | `copy-folder-path.wctl` | `-diagnostics-project-actions` |
| Fork a started, idle Project thread from the header or an agent reply, opening the "(fork)" thread | `fork-thread.wctl` | `-diagnostics-project-actions` |
| A refused fork shows a plain notice; an unstarted thread offers no Fork | `fork-refused.wctl` | `-diagnostics-project-actions` with `-diagnostics-project-fork-conflict`; `-diagnostics-project-speed` |
| A Codex reply's edited-files pill counts the whole-turn diff, including a file written from the shell | `edited-files-turn-diff.wctl` | `-read-preview`, `-send-preview`, `-activity-preview` with `-response-turn-diff-preview` |
| A Claude agent task's commands, edits and a still-running tool | `claude-agent-transcript.wctl` | `-diagnostics-project-subagents` with `-diagnostics-project-claude-tasks` |
| Claude agent tasks grouped Running then Completed with status glyphs and no avatars, "N running" on the pill, and Stop with a confirmation ending as Stopped | `claude-agent-tasks.wctl` | `-diagnostics-project-subagents` with `-diagnostics-project-claude-tasks` |
| A refused Stop explains why and leaves the task running | `claude-agent-task-stop-refused.wctl` | the same with `-diagnostics-project-claude-stop-fails` |
| A desktop paste shows its pasted text, not `pasted_content` tags | `desktop-paste.wctl` | `-diagnostics-project-actions` |
| A `!` shell command and a slash command from Claude Code show as command cards (output and errors collapsible, errors marked), not `bash-input` or `command-name` tags | `claude-command-blocks.wctl` | `-diagnostics-project-actions` with `-diagnostics-project-command-blocks` |
| Select text from a bubble's menu opens the whole message in a selectable sheet | `copy-message.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Forced themes: themed sidebar, chat, composer and coloured code; the Settings theme picker | `theme-appearance.wctl` via `control/theme-sweep.sh DEVICE [light\|dark] -- IDS` | `-diagnostics-project-actions` with `-diagnostics-theme ID` |
| Forced themes on New Chat and its model sheet, Files, Markdown Preview, Source and the expanded viewer, JSON Formatted and Raw, JSON Lines and a text file (`scripts/check-theme` guards the code) | `theme-surfaces.wctl` via `control/theme-sweep.sh --scenario theme-surfaces DEVICE -- IDS` | `-diagnostics-project-speed`; `-workspace-viewer-preview` with the Files fixtures, both with `-diagnostics-theme ID` |
| Message and code fonts on bubbles, a code block, the composer, Markdown Preview and Source and JSON | `font-appearance.wctl` via `control/theme-sweep.sh --scenario font-appearance DEVICE -- MESSAGE+CODE...` | `-diagnostics-project-actions`; `-workspace-viewer-preview` with the Files fixtures, both with `-diagnostics-font MESSAGE+CODE` |
| Settings Font picker: a message and a code font kept across a relaunch, and the bundled font licenses | `font-picker.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Markdown file Preview or Source, remembered across a relaunch | `markdown-viewer.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| A project README's relative image shows from the workspace; a missing or outside-the-project image says so in place; a relative `.md` link opens in the viewer | `markdown-local-references.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| JSON Formatted or Raw, Copy of the shown form, an invalid file, JSON Lines records | `json-viewer.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| Project composer lists Codex and Claude models by provider with a footnote; an other-provider pick shows in the composer with no dialog and the next message carries `projectModel`; the timeline shows "Switched to ..."; a same-provider pick is saved | `provider-switch.wctl` | `-diagnostics-project-provider-switch` with the subagent and chat-layout fixtures |
| A message another thread wrote shows "From <thread>"; "Agent tasks finished: ..." is a compact row | `agent-thread-messages.wctl` | `-diagnostics-project-provider-switch` with the subagent and chat-layout fixtures |
| A Project thread's pull requests: GitHub pill with count and check state, a sheet listing state and checks, a failed refresh that keeps the list | `pull-requests.wctl` | `-diagnostics-project-pull-requests` (and `-refresh-fails`) with the subagent and chat-layout fixtures |
| No pull request pill when the Mac's GitHub CLI is signed out | `pull-requests-hidden.wctl` | the same with `-diagnostics-project-pull-requests-signed-out` |
| Model sheet header stays pinned: Done is reachable after scrolling in New Chat and a Project thread (check on the Duo) | `agent-defaults.wctl` | `-diagnostics-project-speed` with the subagent and chat-layout fixtures |

Fixtures cover app behavior without a paired Mac. Pairing, Tailscale and live
model work still need the live tests in [TESTING.md](TESTING.md).
