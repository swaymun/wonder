# Driving Wonder Testing from the command line

`scripts/wonderctl` lets an agent launch Wonder Testing in a dedicated simulator,
jump to a known state with Diagnostics fixtures, tap and type by accessibility
identifier, and capture evidence. A step takes well under a second and needs no
screenshot model, and a scenario file reruns the same way every time.

Use it to prove iOS behavior. Use computer use or screenshots only for visual
judgment and for flows that no scenario covers yet.

## Run it on the Mac mini

Pass `--host mac-mini`, or export `WONDER_CONTROL_HOST=mac-mini`, to run every
command on the Mac mini instead of this Mac. `build`, `run` and `sync` first copy
the working tree there, including uncommitted and untracked files but not ignored
ones. Each local checkout or worktree gets its own copy under `~/wonder-control/`
on the mini. Evidence is copied back to `.local/control/` after every command.

```sh
scripts/wonderctl --host mac-mini doctor
scripts/wonderctl --host mac-mini build
scripts/wonderctl --host mac-mini run apps/ios/control/scenarios/automations-create.wctl
scripts/wonderctl --host mac-mini --device duo run apps/ios/control/scenarios/automations-create.wctl
```

A scenario failure exits nonzero and saves a screenshot of the failing step.

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
| `tap --id ID [--type Button]` / `--label TEXT` / `--xy X,Y` | Taps through AXe. `--type` picks one of several matches. |
| `hold --id ID` / `--label` / `--contains TEXT` `[--nth N] [--seconds S]` | Long-presses an element, to open a context menu. |
| `clipboard --clear` / `--contains TEXT` / `--not-contains TEXT` / `--show` | Clears or asserts on the simulator pasteboard, so Copy actions are checked by their result. |
| `type TEXT`, `swipe up\|down\|left\|right [--in ID]`, `button home` | Input. `--in` drags inside one element, such as a list in a short panel on the Duo. |
| `back` | Taps the navigation back control; it is a Button on the iPhone and another element type on the Duo. |
| `wait --id ID` / `--label` / `--contains TEXT` `[--gone]` | Polls the accessibility tree. This is the assertion. |
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
| Claude access levels (Ask, Auto, Full access) | `claude-access-picker.wctl` | `-diagnostics-project-read` with the subagent and chat-layout fixtures |
| Permission and question pill replacing the conversation | `approval-dock.wctl` | `-phone-approval-preview command` arriving via `-attention-arrives-preview`; `-question-preview` |
| Host default model, resolved effort and Speed in New Chat and a Project thread | `agent-defaults.wctl` | `-diagnostics-project-speed` with the subagent and chat-layout fixtures |
| Settings Default models: Codex and Claude pickers, a saved choice, and Try again after a failed load | `default-models.wctl` | `-diagnostics-default-models` and `-diagnostics-default-models-fail-once` with the subagent and chat-layout fixtures |
| Copy a message from a bubble's long-press menu | `copy-message.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Copy a chat as Markdown from the header menu | `copy-markdown.wctl` | `-read-preview`, `-send-preview`, `-project-files-conversation-preview` |
| Copy a thread's folder path from its sidebar long-press menu | `copy-folder-path.wctl` | `-diagnostics-project-actions` |
| Fork a started, idle Project thread from the header or an agent reply, opening the "(fork)" thread | `fork-thread.wctl` | `-diagnostics-project-actions` |
| A refused fork shows a plain notice; an unstarted thread offers no Fork | `fork-refused.wctl` | `-diagnostics-project-actions` with `-diagnostics-project-fork-conflict`; `-diagnostics-project-speed` |
| A Claude agent task's commands, edits and a still-running tool | `claude-agent-transcript.wctl` | `-diagnostics-project-subagents` with `-diagnostics-project-claude-tasks` |
| A desktop paste shows its pasted text, not `pasted_content` tags | `desktop-paste.wctl` | `-diagnostics-project-actions` |
| Select text from a bubble's menu opens the whole message in a selectable sheet | `copy-message.wctl` | `-diagnostics-project-actions` with the subagent and chat-layout fixtures |
| Forced themes: themed sidebar, chat, composer and coloured code; the Settings theme picker | `theme-appearance.wctl` via `control/theme-sweep.sh DEVICE [light\|dark] -- IDS` | `-diagnostics-project-actions` with `-diagnostics-theme ID` |
| Markdown file Preview or Source, remembered across a relaunch | `markdown-viewer.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| JSON Formatted or Raw, Copy of the shown form, an invalid file, JSON Lines records | `json-viewer.wctl` | `-workspace-viewer-preview` with the Files fixtures |
| Project composer lists Codex and Claude models by provider with a footnote; an other-provider pick shows in the composer with no dialog and the next message carries `projectModel`; the timeline shows "Switched to ..."; a same-provider pick is saved | `provider-switch.wctl` | `-diagnostics-project-provider-switch` with the subagent and chat-layout fixtures |
| A message another thread wrote shows "From <thread>"; "Agent tasks finished: ..." is a compact row | `agent-thread-messages.wctl` | `-diagnostics-project-provider-switch` with the subagent and chat-layout fixtures |
| Model sheet header stays pinned: Done is reachable after scrolling in New Chat and a Project thread (check on the Duo) | `agent-defaults.wctl` | `-diagnostics-project-speed` with the subagent and chat-layout fixtures |

Fixtures cover app behavior without a paired Mac. Pairing, Tailscale and live
model work still need the live tests in [TESTING.md](TESTING.md).
