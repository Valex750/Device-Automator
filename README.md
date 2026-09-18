# Device Automator

A macOS MCP server. A coding agent uses it to boot a simulator, install a configured iOS app, and drive that app from the accessibility tree. It never writes into the driven app’s source tree.

This README is the unattended-agent contract. Follow the data flow and the loop below. Do not invent a second session, kill processes, or verify UI from screenshots.

## Unattended contract

Do this without asking, in one MCP connection:

1. `get_target` — confirm app, scheme, bundle id, device.
2. `boot_simulator` if the device is not booted (`list_devices` if you need a UDID).
3. `install_and_run` after a code change (or once at the start if the binary is stale).
4. `observe` — read `hierarchyPath`. Tap `hitPoint`s from that tree.
5. `tap` / `type` / `swipe` / `double_tap` / `press_button` as needed, then `observe` again.
6. After another code change, `install_and_run` again, then `observe` / `tap` on the **same** DeviceInteraction session.
7. Leave the session open. Do not call `end_session` between rebuilds.

Stop and ask a human only for:

- Xcode **Settings → Intelligence → Allow External Agents to Use Xcode Tools** (once per Mac).
- The first **"Allow 'DeviceAutomator' to access Xcode?"** dialog (once per daemon process).
- Installing an **iOS 27** simulator runtime, or a codesigning identity, when those are missing.

Never:

- Kill `DeviceAutomator` processes, including `--daemon`.
- Call `mcp_auth` to “fix” a session. Use `reset_session`, then `observe`.
- Start a second DeviceInteraction session (do not call Xcode `DeviceInteractionStart*` yourself).
- Treat `applicationState: NotRun` as “need `install_and_run`” when `hierarchyPath` exists.
- Open `screenshotPath` / `thumbnailScreenshotPath`, or call `screenshot`, to decide what to tap.
- Modify Device Automator source while driving another app.

If MCP returns **Not connected**, `mcp_auth` is correct: that only reconnects a stdio proxy to the existing daemon. If a tool returns identifier-in-use, session-not-found, or no session key, call `reset_session` then `observe`. Do not wait 20 seconds and do not kill anything.

Cap UI fix/re-verify at **5** attempts. Same symptom twice with no new evidence: stop and report the hierarchy lines.

## Process data flow

One Xcode DeviceInteraction session is owned by **one daemon per machine**. Every MCP client is a stdio proxy onto that daemon.

```
Cursor / Claude MCP client
  → /bin/bash  scripts/run-mcp.sh
      if ~/Library/Application Support/DeviceAutomator/bin/DeviceAutomator exists:
        exec that binary (no rebuild)
      else:
        xcodebuild Release if needed, ditto + codesign, then exec
    → DeviceAutomator   (stdio proxy; one per MCP connection)
      → unix socket  ~/Library/Application Support/DeviceAutomator/engine.sock
        → DeviceAutomator --daemon   (one; setsid so it outlives MCP disconnect)
          → xcrun mcpbridge  →  Xcode DeviceInteraction
          → /usr/bin/xcodebuild, xcrun devicectl, xcrun simctl
```

`ps` may show several `DeviceAutomator` binaries (Cursor user MCP + project MCP + Claude). That is expected. Exactly one should have `--daemon`. Proxies must attach; they must not start Xcode sessions.

On first proxy start, the process binds the socket if needed and spawns `--daemon`. Later proxies connect to the same socket. `mcp_auth` starts a new proxy; the daemon and its Xcode session stay. A newer binary (`0.2.0+`) SIGTERMs a stale daemon of a different version, then starts a new one.

The daemon log is `~/Library/Application Support/DeviceAutomator/engine.log`.

## Tool data flow

All tools run inside the daemon (serialized). They use `get_target`’s current app unless you pass `device`.

### No Xcode session: list / boot / screenshot / cold install

```
list_targets / get_target / add_target / set_target / remove_target
  → ~/Library/Application Support/DeviceAutomator/config.json

list_devices
  → xcrun devicectl list devices

boot_simulator / shutdown_simulator
  → xcrun simctl boot | shutdown  <UDID>

screenshot
  → xcrun devicectl device capture screenshot
  → PNG under ~/Library/Application Support/DeviceAutomator/screenshots/
    (or an explicit destination outside any target project)

install_and_run   when the daemon has NO live DeviceInteraction session
  → xcodebuild -scheme … -destination id=<UDID> -derivedDataPath
       ~/Library/Application Support/DeviceAutomator/derived/<target>/
  → find .app under Build/Products/
  → xcrun devicectl device install app   (fallback: simctl install)
  → xcrun devicectl device process launch (fallback: simctl launch)
  → does NOT call DeviceInteractionStart*
```

`set_target` writes config and **ends** any live DeviceInteraction session.

### Live UI: observe / tap / rebuild

```
observe / tap / double_tap / swipe / type / press_button / set_orientation
  → if daemon already has sessionKey: reuse it
  → else:
       XcodeOpenWorkspace | XcodeListWindows  → workspace/tab id
       mint unique sessionIdentifier  "Device Automator <8 hex>"
       DeviceInteractionStartWorkspaceSession
         (if that tool is unavailable: DeviceInteractionStartSession,
          never a second start on an identifier that already burned)
       persist key in interaction-session.json
       on in-use / no key / stateful error: EndSession that id, mint another, backoff
  → DeviceInteractionSynthesize  (empty command = observe only)
  → rewrite applicationState NotRun → Running when a hierarchy was captured
  → artifacts under /var/folders/…/T/ActionArtifacts/default/
       filenames use the session id, e.g. Device Automator FA002CBC-…-hierarchy.txt
       the folder name `default` is Xcode’s dump slot, not the session id

install_and_run   when the daemon HAS a live session
  → DeviceInteractionInstallAndRun(existing interactionSessionKey)
  → on failure: same xcodebuild + devicectl/simctl path as cold install
  → does NOT StartSession and does NOT replace the live key
```

`end_session` / `reset_session` call Xcode `DeviceInteractionEndSession`, clear the key, keep the daemon and mcpbridge. The next `observe` / `tap` mints a **new** identifier. Prefer leaving the session open. Use `reset_session` when the session is wedged.

## Observe result

`observe` and gesture tools return JSON text with at least:

| Field | Use |
| --- | --- |
| `hierarchyPath` | Source of truth. Read/grep this file. Tap its `hitPoint`s. |
| `applicationState` | `Running` when a live tree was captured. Do not reinstall because of `NotRun` if `hierarchyPath` is set. |
| `screenshotPath` / `thumbnailScreenshotPath` | Ignore unless the tree cannot answer a layout/color question. |
| `logsPath` | Optional device logs. |

Hierarchy lines look like:

```
Application, pid: 65720, label: 'Lift Planner'
Button, {{346.0, 66.0}, {36.0, 36.0}}, identifier: 'ellipsis.circle', label: 'More', hitPoint: {364.0, 84.0}
```

`tap` arguments `x`/`y` are that `hitPoint`, not screenshot pixels.

## Drive from the accessibility tree

1. After every `observe` / `tap` / `type` / `swipe` / `double_tap`, grep `hierarchyPath` first.
2. Find the control by `label` / `identifier`. Tap its `hitPoint`.
3. Confirm behavior from the tree (labels, `Selected`, enabled, presence/absence, navigation). Quote those lines in the report.
4. Do not open `screenshotPath`. Do not call `screenshot` to drive or verify UI when `observe` works.
5. If a PNG and the tree disagree, the tree wins.

**Screenshot exception.** Open a PNG only when the tree cannot answer the check: layout, spacing, or color; a missing accessibility label; or a visual-only issue the user asked about. Say why the tree was insufficient. Still tap `hitPoint`s from the tree.

`screenshot` is a CoreDevice connectivity check for runtimes that lack Device Interaction, not feature verification.

## Tools (19)

| Tool | What it actually does |
| --- | --- |
| `list_targets`, `get_target`, `add_target`, `remove_target` | Read/write `config.json`. Never edits the app. |
| `set_target` | Selects the current app and **ends** the live DeviceInteraction session. |
| `list_devices` | `devicectl list devices`. |
| `boot_simulator`, `shutdown_simulator` | `simctl boot` / `shutdown`. |
| `screenshot` | CoreDevice PNG into Application Support (or an explicit path outside target trees). |
| `install_and_run` | Build + install + launch. **Must not** start a second DeviceInteraction session. Live session → `DeviceInteractionInstallAndRun` or CLI fallback. No session → CLI only; `observe` opens the one session later. |
| `observe` | `DeviceInteractionSynthesize` with an empty command. Reuses the live session or starts a new identifier. |
| `tap`, `double_tap`, `swipe`, `type`, `press_button` | Synthesize input, then a new hierarchy. Coordinates from the latest `hitPoint`. |
| `set_orientation` | `devicectl` first; DeviceInteraction `orientation …` if that fails. |
| `end_session` | Optional close. Next `observe` starts a new identifier. Do not call this between rebuilds. |
| `reset_session` | Same close, intended for a wedged session. Does not kill Device Automator. |

## Files on this Mac

| Path | Role |
| --- | --- |
| `~/Library/Application Support/DeviceAutomator/bin/DeviceAutomator` | Installed binary `run-mcp.sh` execs. |
| `…/config.json` | Targets. Override with `DEVICE_AUTOMATOR_CONFIG`. |
| `…/engine.sock`, `engine.pid`, `engine.lock` | Single daemon. |
| `…/engine.log` | Daemon + session start log. |
| `…/interaction-session.json` | Last Xcode identifier/key (reclaimed if the daemon dies). |
| `…/identifier-cooldown.json` | Recently used identifiers (do not reuse for ~45s). |
| `…/derived/<target>/` | `xcodebuild` derived data for cold `install_and_run`. |
| `…/screenshots/` | `screenshot` tool PNGs. |
| `/var/folders/…/T/ActionArtifacts/default/DeviceInteractionSynthesize/` | Xcode hierarchy + PNG dumps. |

Writes into a configured target’s project tree are refused.

## Agent setup checklist (new Mac, new project)

Follow in order. Step 6 needs a human in a GUI and cannot be scripted.

1. **Check prerequisites.**
   ```bash
   uname -m                                # expect arm64
   xcodebuild -version                     # expect Xcode 27.x
   xcrun simctl list runtimes | grep -i ios # expect an iOS 27.x runtime
   ```
   `observe` / `tap` / `type` / `swipe` only work on an **iOS 27** simulator. Other runtimes still support `list_devices`, `boot_simulator`, and `screenshot`. If there is no iOS 27 runtime, ask the user to install one via Xcode → Settings → Platforms.

2. **Clone and build.**
   ```bash
   git clone https://github.com/Valex750/Device-Automator.git
   cd Device-Automator/DeviceAutomator
   xcodebuild -project DeviceAutomator.xcodeproj -scheme DeviceAutomator \
     -configuration Release -destination 'platform=macOS,arch=arm64' build
   ```
   If signing fails here, append `CODE_SIGN_IDENTITY=-` to that command. That is only the one-off build; the installed copy is still re-signed in the next step.

3. **Pick a stable signing identity** and put it in `scripts/run-mcp.sh`.
   ```bash
   security find-identity -v -p codesigning
   ```
   A free personal "Apple Development" certificate is enough. It does **not** need to match the identity that signs the app you will drive. Edit `SIGNING_IDENTITY="..."` near the top of `scripts/run-mcp.sh`. If the list is empty, ask the user to open Xcode → Settings → Accounts and add their Apple ID, then retry.

4. **Register the MCP server** with the absolute path to `scripts/run-mcp.sh` **on this Mac**. The folder name contains a space: `command` must be `/bin/bash`, script path in `args`.
   ```json
   {
     "mcpServers": {
       "device-automator": {
         "command": "/bin/bash",
         "args": ["/ABSOLUTE/PATH/TO/Device Automator/scripts/run-mcp.sh"]
       }
     }
   }
   ```
   Reload MCP. Confirm `list_targets` and that **19** tools are listed, including `reset_session`. Prefer **one** MCP registration (user *or* project, not both). Two registrations still share the daemon; they must not each StartSession.

5. **Configure the target app.** A missing `config.json` is seeded with a placeholder (`DefaultTargets.liftPlanner`) for the original author’s Mac. On any other Mac, call `add_target` then `set_target` before `observe`. `add_target` parameters are `snake_case`; `config.json` fields are `camelCase`.
   ```
   add_target(
     name: "<ShortName>",
     project_path: "/ABSOLUTE/PATH/TO/App.xcodeproj",
     scheme: "<SchemeName>",
     bundle_id: "com.example.app",
     device: "<UDID from list_devices>"
   )
   set_target(name: "<ShortName>")
   ```
   Prefer an **iOS 27** simulator UDID.

6. **Human-only approvals.** There is no CLI for these:
   - Xcode: **Settings → Intelligence → Model Context Protocol → Allow External Agents to Use Xcode Tools** → **Always**. `xcrun mcp-server status` should report permission enabled.
   - First `observe` / `tap`: **"Allow 'DeviceAutomator' to access Xcode?"** — ask the user to click **Allow**. It is scoped to the daemon process, not the code signature. It should not reappear on every `mcp_auth`. It can reappear after a daemon restart (including a Device Automator rebuild).

7. **Verify.** These succeed without DeviceInteraction:
   ```
   list_targets
   get_target
   list_devices
   screenshot
   ```
   Then `observe` (dialog from step 6 on first use). Confirm `hierarchyPath` is a live tree (`Application, pid: …`). Drive with `hitPoint`s.

If the app needs a paired watch:

```bash
xcrun simctl pair <watch-udid> <phone-udid>
xcrun simctl pair_activate <pair-udid>
xcrun simctl boot <watch-udid>
```

## Requirements

- Apple Silicon Mac
- Xcode 27 with the **iOS 27** simulator runtime
- An MCP client that launches a stdio server (Cursor or Claude Code)
- Xcode Intelligence → **Allow external agents**

Build on the Mac that will run it. Do not copy the binary from another machine.

```bash
git clone https://github.com/Valex750/Device-Automator.git
cd Device-Automator/DeviceAutomator
xcodebuild -project DeviceAutomator.xcodeproj -scheme DeviceAutomator \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
```

If that signing fails:

```bash
xcodebuild -project DeviceAutomator.xcodeproj -scheme DeviceAutomator \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- build
```

`scripts/run-mcp.sh` installs a re-signed copy to `~/Library/Application Support/DeviceAutomator/bin/DeviceAutomator` **only when that file is missing**. If the file exists, it is exec’d as-is. After rebuilding Device Automator itself, install with `ditto` + `codesign` (same identity as `SIGNING_IDENTITY`) or delete the installed binary and relaunch MCP.

Manual stdio smoke test (proxy; the daemon stays in the background):

```bash
/bin/bash "/ABSOLUTE/PATH/TO/Device Automator/scripts/run-mcp.sh"
```

`--self-test` on the binary runs identifier / observe-normalization checks (no Xcode).

## Configure a target app

`~/Library/Application Support/DeviceAutomator/config.json`

| `config.json` (camelCase) | `add_target` (snake_case) | Meaning |
| --- | --- | --- |
| `name` | `name` | Short name, e.g. `MyApp` |
| `projectPath` | `project_path` | Absolute `.xcodeproj` or `.xcworkspace` |
| `scheme` | `scheme` | Xcode scheme |
| `bundleId` | `bundle_id` | App bundle identifier |
| `device` | `device` | Simulator UDID |

## Configure Cursor / Claude Code

Same `mcpServers` block as step 4 (`mcp.example.json`). Paths must be absolute. Cursor’s “Allow external agents” approval does not apply to Claude Code — approve Claude Code in Xcode separately.

After reload, run the unattended loop at the top of this file.

## Skill template: full dev cycle

Create `.claude/skills/dev-cycle/SKILL.md` **inside the app being driven** (not this repo):

````markdown
---
name: dev-cycle
description: Full plan-implement-run-verify-fix loop for developing a feature or fixing a bug in this app, using Device Automator to drive the iOS Simulator like a real user rather than just reading code or screenshots. Use when the user asks to build/implement/add a feature, fix a bug end-to-end, or invokes /dev-cycle <description>.
---

# Feature development cycle (plan → build → verify → fix)

Use Device Automator MCP tools. Follow that project’s README data flow. The work is not done until the accessibility tree shows the change working.

## The cycle

1. **Plan.** Read existing code. Call `get_target` first.
2. **Implement** in this app’s source. Never modify Device Automator.
3. **Build and launch.** `install_and_run`. If a DeviceInteraction session is already live, this must not start a second one.
4. **Verify.** `observe`, then `tap` / `type` / `swipe` using `hitPoint`s from `hierarchyPath`. Quote tree lines. Do not open `screenshotPath` unless the tree cannot answer the check.
5. **Fix and re-verify.** Change this app, `install_and_run` again, `observe` / `tap` on the same session. Cap at 5 fix attempts. Same symptom twice: stop.
6. **Close out.** Leave the session open. Do not `end_session` between rebuilds. If wedged: `reset_session` then `observe`. Never kill DeviceAutomator.

## Rules

- Coordinates come only from `observe` `hitPoint`s.
- `applicationState` plus a live `hierarchyPath` means the app is running; do not reinstall because of `NotRun`.
- First `observe`/`tap` may need a human to click Xcode’s Allow dialog — stop and ask; do not retry blindly.
- `mcp_auth` only when MCP is Not connected, not to recover a session.
````

## Skill template: verify-in-simulator

Create `.claude/skills/verify-in-simulator/SKILL.md` **inside the app being driven**:

````markdown
---
name: verify-in-simulator
description: Verify that a UI-visible change actually works by running the app in the iOS Simulator via Device Automator (build, launch, observe, tap), using the accessibility tree as the source of truth rather than screenshots. Use after implementing or fixing a UI-visible change, when asked to confirm/test/verify a feature works, or before considering such a change done.
---

# Verify in Simulator

Plan/implement elsewhere. This skill only proves the UI works.

1. `get_target`
2. `install_and_run` (must not start a second DeviceInteraction session if one is live)
3. `observe` → drive with `hitPoint`s from `hierarchyPath` → `observe` after each gesture
4. On failure: fix this app, `install_and_run`, repeat step 3. Cap 5 attempts.
5. Leave the session open. Wedged: `reset_session` then `observe`. Never kill DeviceAutomator.

Tree first. Do not Read `screenshotPath` or call `screenshot` unless the tree cannot answer the check. If they disagree, the tree wins.
````

Standing reminder for the driven app’s `CLAUDE.md`:

```markdown
## Verifying UI changes

Before considering a UI-visible change done, verify it in the iOS Simulator with Device Automator: `get_target` → `install_and_run` → `observe` → tap `hitPoint`s from `hierarchyPath`. Leave the DeviceInteraction session open across rebuilds. If the session is wedged, `reset_session` then `observe`. Do not kill DeviceAutomator. Do not open screenshots when the tree has the answer.
```

## Recovery (unattended)

| Symptom | Action |
| --- | --- |
| MCP **Not connected** | `mcp_auth`. New proxy attaches to the existing daemon. |
| identifier in use / recently used / `IDEStatefulActionError` / no session key / session not found | `reset_session`, then `observe`. Do not kill. Do not wait for a human cooldown. |
| `applicationState: NotRun` but `hierarchyPath` is a live tree | Trust the tree. Do not `install_and_run` for that reason. |
| `install_and_run` mentions xcodebuild fallback | Session is still the live one. Continue with `observe`. |
| Allow dialog / no iOS 27 runtime / empty signing identities | Stop and ask the user. |
| Several `DeviceAutomator` PIDs, one `--daemon` | Expected. Do not kill. |
| Need a log | `~/Library/Application Support/DeviceAutomator/engine.log` |

Xcode `XcodeListWindows` returns unquoted `tabIdentifier: windowtab-…, workspacePath: …`. Device Automator parses that. Several Xcode tools return `isError` / “not enabled” without a JSON-RPC error; the daemon treats “not enabled” as a missing tool and “identifier in use” as a burned id (new identifier, not a second start on the same id).

The Allow dialog is Xcode’s per-process MCP consent, separate from “Allow External Agents” and from macOS TCC. If Agent Activity fills with stale Inactive rows after daemon restarts, the user can click **Clear**.

`SIGNING_IDENTITY` in `scripts/run-mcp.sh` must be a real codesigning name from `security find-identity -v -p codesigning`, not ad-hoc (`--sign -`).
