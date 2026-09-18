# Device Automator

A macOS MCP server. A coding agent uses it to boot a simulator, install a configured iOS app, and drive that app from the accessibility tree. It never writes into the driven app’s source tree.

This README is the unattended-agent contract. Follow the data flow and the loop below. Do not invent a second session, kill processes, or verify UI from screenshots.

## Unattended contract

Do this without asking, in one MCP connection:

1. `get_target` — confirm app, scheme, bundle id, device.
2. `boot_simulator` if the device is not booted (`list_devices` if you need a UDID).
3. `install_and_run` after a code change (or once at the start if the binary is stale).
4. `observe` — **Grep/Read only the `.txt` at `hierarchyPath`**. Ignore `screenshotPath`. Tap `hitPoint`s from matching tree lines.
5. `tap` / `type` / `swipe` / `double_tap` / `press_button` as needed, then `observe` again. After every gesture, Grep the new `hierarchyPath` before doing anything else.
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
- `Read` `screenshotPath` / `thumbnailScreenshotPath`, or call `screenshot`, because `observe` returned those paths, to see “if the screen loaded,” or to pick a tap target.
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
| `hierarchyPath` | **Only source of truth.** A `.txt` accessibility dump. Grep/Read this file. Quote lines. Tap its `hitPoint`s. |
| `applicationState` | `Running` when a live tree was captured. Do not reinstall because of `NotRun` if `hierarchyPath` is set. |
| `screenshotPath` / `thumbnailScreenshotPath` | **Do not Read.** Returned for Xcode; not part of the default loop. PNG fallback only after the text procedure below has failed. |
| `logsPath` | Optional device logs. |

## Text-first procedure (mandatory)

After **every** `observe` / `tap` / `type` / `swipe` / `double_tap`:

1. Take `hierarchyPath` from the tool JSON. It ends in `-hierarchy.txt`.
2. **Grep** that file (or Read the `.txt` if it is short). Do **not** Read any `.png` in the same step, even if `screenshotPath` is sitting next to it in the JSON.
3. Search for the control with `label:` / `identifier:` / `Button` / `Selected` / `Disabled`.
4. Quote the matching line(s). If you will tap, use that line’s `hitPoint: {x, y}` as `tap` `x`/`y` — integers are fine (`364.0` → `364`).
5. Decide pass/fail from those lines only (label present, `Selected`, `Disabled`, navigation title, alert text). Put the quoted lines in the report.

### Worked example (do this)

`observe` returns:

```json
{
  "hierarchyPath": "/var/folders/…/Device Automator FA002CBC-20_05_31_006-hierarchy.txt",
  "screenshotPath": "/var/folders/…/Device Automator FA002CBC-20_05_31_006-screenshot.png",
  "thumbnailScreenshotPath": "/var/folders/…/Device Automator FA002CBC-20_05_31_006-thumbnailScreenshot.png",
  "applicationState": "Running"
}
```

Grep the **`.txt` only**:

```
Grep  path: …/Device Automator FA002CBC-20_05_31_006-hierarchy.txt
      pattern: label: 'More'|label: 'Workout'|identifier: 'ellipsis
```

Tree hit:

```
Application, pid: 65720, label: 'Lift Planner'
StaticText, … label: 'Workout', hitPoint: {201.0, 84.0}
Button, {{346.0, 66.0}, {36.0, 36.0}}, identifier: 'ellipsis.circle', label: 'More', hitPoint: {364.0, 84.0}
```

Then `tap` `x: 364` `y: 84`. Report those three lines. **Do not** `Read` either PNG.

Wrong (what Cursor did on Lift Planner): `Read` `screenshotPath` “to see the UI,” then guess a tap. `observe` always attaches PNGs; that is not permission to open them.

### PNG fallback (only after text failed)

Text has **failed** only when you already Grepped the `.txt` and still cannot answer the check because:

- no node has a `label` / `identifier` for the control (missing accessibility), or
- the question is color, spacing, overlap, or clipping — nothing in the dump encodes it, or
- the user asked about a visual-only regression.

Then you may `Read` `screenshotPath`. In the same message, state: the grep pattern, that it missed, and why pixels are required. Taps still use `hitPoint`s from the tree if any node exists. If the PNG and the tree disagree, **the tree wins** — report the tree lines, not the image.

`layout` / “see if it loaded” / “confirm the screen” are **not** failures of the text. A `NavigationBar` identifier, `StaticText` label, or `Application, pid:` line already answers those.

The `screenshot` **tool** is a CoreDevice connectivity check for runtimes that lack Device Interaction. Do not call it while `observe` works.

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
   Then `observe` (dialog from step 6 on first use). Grep the `.txt` at `hierarchyPath` for `Application, pid:` and the screen’s labels. Drive with those `hitPoint`s. Do not `Read` `screenshotPath`.

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

Use Device Automator MCP tools. Follow Device Automator’s README **Text-first procedure**. The work is not done until quoted `hierarchyPath` lines show the change working.

## The cycle

1. **Plan.** Read existing code. Call `get_target` first.
2. **Implement** in this app’s source. Never modify Device Automator.
3. **Build and launch.** `install_and_run`. If a DeviceInteraction session is already live, this must not start a second one.
4. **Verify (text only).** `observe`. Grep/Read **only** the `.txt` at `hierarchyPath`. Find `label:` / `identifier:`. `tap` that line’s `hitPoint`. Quote the lines. Do **not** `Read` `screenshotPath` or `thumbnailScreenshotPath` because `observe` returned them. Do **not** call the `screenshot` tool.
5. **Fix and re-verify.** Change this app, `install_and_run` again, then step 4 on the same session. Cap at 5 fix attempts. Same symptom twice: stop.
6. **Close out.** Leave the session open. Do not `end_session` between rebuilds. If wedged: `reset_session` then `observe`. Never kill DeviceAutomator.

## PNG fallback (only after text failed)

Grep the `.txt` first. Text has failed only if that grep cannot answer because the node has no `label`/`identifier`, or the check is color/overlap/clipping with no tree attribute, or the user asked about a visual-only regression. Then you may Read the PNG; say which grep missed and why. Taps still use `hitPoint`s. Tree beats PNG. “Did the screen load?” is answered by `Application, pid:` / `NavigationBar` / `StaticText` in the dump — not by opening the screenshot.

## Rules

- Coordinates come only from tree `hitPoint`s, never from pixels.
- `applicationState` plus a live `hierarchyPath` means the app is running; do not reinstall because of `NotRun`.
- First `observe`/`tap` may need a human to click Xcode’s Allow dialog — stop and ask; do not retry blindly.
- `mcp_auth` only when MCP is Not connected, not to recover a session.
````

## Skill template: verify-in-simulator

Create `.claude/skills/verify-in-simulator/SKILL.md` **inside the app being driven**:

````markdown
---
name: verify-in-simulator
description: Verify that a UI-visible change actually works by running the app in the iOS Simulator via Device Automator (build, launch, observe, tap), using the accessibility tree .txt dump as the source of truth. Screenshots are a last resort after a grep of that dump cannot answer the check. Use after implementing or fixing a UI-visible change, when asked to confirm/test/verify a feature works, or before considering such a change done.
---

# Verify in Simulator

Plan/implement elsewhere. This skill only proves the UI works, from **textual** hierarchy data.

## After every observe / tap / type / swipe

1. `observe` (or the gesture tool) returns JSON with `hierarchyPath` (a `-hierarchy.txt`) and `screenshotPath` (a PNG).
2. **Grep or Read the `.txt` only.** Do not `Read` `screenshotPath` or `thumbnailScreenshotPath` in this step. `observe` always attaches PNGs; that is not permission to open them.
3. Find the control: `label: '…'` / `identifier: '…'` / `Button` / `Selected` / `Disabled`.
4. Quote the matching line. `tap` its `hitPoint: {x, y}` (`364.0` → `x: 364`, `y: 84`).
5. Pass/fail from those lines. Put the quotes in the report.

Example: Grep `label: 'More'|label: 'Workout'` on the `.txt`, then `tap` `364, 84` from `label: 'More', hitPoint: {364.0, 84.0}`. Do not open the PNG “to see the UI.”

## PNG fallback (only after text failed)

Text failed only if that grep cannot answer because: no `label`/`identifier` for the control; or the check is color/overlap/clipping with no tree field; or the user asked about a visual-only regression. Then Read the PNG and say which grep missed. Taps still use `hitPoint`s. Tree wins if they disagree. “Did it load?” / “what screen is this?” are answered by `Application, pid:` and `NavigationBar` / `StaticText` in the dump.

## Steps

1. `get_target`
2. `install_and_run` (must not start a second DeviceInteraction session if one is live)
3. Text-first loop above, including edge cases (empty/error states)
4. On failure: fix this app, `install_and_run`, repeat step 3. Cap 5 attempts.
5. Leave the session open. Wedged: `reset_session` then `observe`. Never kill DeviceAutomator. Never call the `screenshot` tool while `observe` works.
````

Standing reminder for the driven app’s `CLAUDE.md`:

```markdown
## Verifying UI changes

Before considering a UI-visible change done, verify it with Device Automator from the **text** dump: `get_target` → `install_and_run` → `observe` → Grep the `.txt` at `hierarchyPath` → tap that line’s `hitPoint`. Do not `Read` `screenshotPath` unless that grep cannot answer (missing label, or color/overlap with no tree field). Leave the DeviceInteraction session open across rebuilds. Wedged: `reset_session` then `observe`. Do not kill DeviceAutomator.
```

## Recovery (unattended)

| Symptom | Action |
| --- | --- |
| MCP **Not connected** | `mcp_auth`. New proxy attaches to the existing daemon. |
| identifier in use / recently used / `IDEStatefulActionError` / no session key / session not found | `reset_session`, then `observe`. Do not kill. Do not wait for a human cooldown. |
| `applicationState: NotRun` but `hierarchyPath` is a live tree | Trust the tree. Do not `install_and_run` for that reason. |
| Tempted to open `screenshotPath` to “see the UI” | Grep the `.txt` at `hierarchyPath` instead. PNG only after that grep cannot answer. |
| `install_and_run` mentions xcodebuild fallback | Session is still the live one. Continue with `observe`. |
| Allow dialog / no iOS 27 runtime / empty signing identities | Stop and ask the user. |
| Several `DeviceAutomator` PIDs, one `--daemon` | Expected. Do not kill. |
| Need a log | `~/Library/Application Support/DeviceAutomator/engine.log` |

Xcode `XcodeListWindows` returns unquoted `tabIdentifier: windowtab-…, workspacePath: …`. Device Automator parses that. Several Xcode tools return `isError` / “not enabled” without a JSON-RPC error; the daemon treats “not enabled” as a missing tool and “identifier in use” as a burned id (new identifier, not a second start on the same id).

The Allow dialog is Xcode’s per-process MCP consent, separate from “Allow External Agents” and from macOS TCC. If Agent Activity fills with stale Inactive rows after daemon restarts, the user can click **Clear**.

`SIGNING_IDENTITY` in `scripts/run-mcp.sh` must be a real codesigning name from `security find-identity -v -p codesigning`, not ad-hoc (`--sign -`).
