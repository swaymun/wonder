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
ones. Evidence is copied back to `.local/control/` after every command.

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
on the Duo. `build`, `run`, `device` and `install` take a lock, so two agents
cannot drive the same simulator at once.

The iPhone Duo runs Wonder on its unfolded display. Fold posture is only available
from Simulator's Device Hub, so check folding by hand. Most app extensions do not
run on the Duo simulator. Do not change a Duo's display power with
`simctl io screenConfig`: it moves the primary display and only `device --erase`
restores it.

## Commands

| Command | Effect |
| --- | --- |
| `doctor` | Reports Xcode, AXe, the simulator, the build and other booted simulators. |
| `device [--erase] [--shutdown]` | Creates and boots the simulator. `--erase` gives a fresh install. |
| `build [--no-install]` | Builds `WonderTesting` in `TestingDiagnostics` and installs it. |
| `launch --fixture NAME …` | Relaunches the app with launch flags. `fixtures` lists them. |
| `open URL` | Opens a deep link. |
| `tap --id ID [--type Button]` / `--label TEXT` / `--xy X,Y` | Taps through AXe. `--type` picks one of several matches. |
| `type TEXT`, `swipe up\|down\|left\|right`, `button home` | Input. |
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

Fixtures cover app behavior without a paired Mac. Pairing, Tailscale and live
model work still need the live tests in [TESTING.md](TESTING.md).
