# Device Automator

A macOS MCP server that lets any coding agent drive an iOS app in Xcode's Device Hub (Device Interaction). The agent boots a simulator, builds and installs a configured app, then taps, types, and swipes it using the app's **accessibility tree** as the source of truth. Device Automator never writes into the driven app's source tree.

Works with any MCP client that can launch a stdio server: Claude Code, Cursor, Codex CLI, Gemini CLI, Zed, and others.

**If you are an AI agent:** read this file top to bottom.

1. [Set up](#setup) (once per Mac).
2. [Register the server](#register-the-mcp-server) with your client.
3. [Configure the target app](#configure-the-target-app).
4. Follow the [drive loop](#drive-loop) and the [text-first procedure](#text-first-procedure).

Do not invent a second session, kill processes, or verify UI from screenshots.

## Requirements

- Apple Silicon Mac
- Xcode 27 with an **iOS 27** simulator runtime (`observe` / `tap` / `type` / `swipe` need it; other runtimes only support `list_devices`, `boot_simulator`, `screenshot`)
- A codesigning identity (a free personal "Apple Development" certificate is enough)
- An MCP client that launches stdio servers
- Xcode **Settings → Intelligence → Model Context Protocol → Allow External Agents to Use Xcode Tools**

Build on the Mac that will run it. Do not copy the binary from another machine.

## Setup

Follow in order. Step 5 needs a human in a GUI and cannot be scripted.

1. **Check prerequisites.**
   ```bash
   uname -m                                 # expect arm64
   xcodebuild -version                      # expect Xcode 27.x
   xcrun simctl list runtimes | grep -i ios # expect an iOS 27.x runtime
   ```
   No iOS 27 runtime: ask the user to install one via Xcode → Settings → Platforms.

2. **Clone and build.**
   ```bash
   git clone https://github.com/Valex750/Device-Automator.git
   cd Device-Automator/DeviceAutomator
   xcodebuild -project DeviceAutomator.xcodeproj -scheme DeviceAutomator \
     -configuration Release -destination 'platform=macOS,arch=arm64' build
   ```
   If signing fails, append `CODE_SIGN_IDENTITY=-`. That only affects this one-off build; the installed copy is re-signed in the next step.

3. **Pick a stable signing identity** for `scripts/run-mcp.sh`.
   ```bash
   security find-identity -v -p codesigning
   ```
   It does **not** need to match the identity that signs the app you will drive. By default the script uses the first valid `Apple Development` identity. To pin one, write its name to `~/Library/Application Support/DeviceAutomator/signing-identity` (or set `DEVICE_AUTOMATOR_SIGNING_IDENTITY`); nothing in the repo needs editing. It must be a real identity name, not ad-hoc (`--sign -`). If the list is empty, ask the user to add their Apple ID in Xcode → Settings → Accounts, then retry.

4. **Register the MCP server** ([below](#register-the-mcp-server)), then confirm `list_targets` works and that **20** tools are listed, including `reset_session`.

5. **Human-only approvals.** There is no CLI for these:
   - Xcode: **Settings → Intelligence → Model Context Protocol → Allow External Agents to Use Xcode Tools** → **Always**. `xcrun mcp-server status` should report permission enabled.
   - First `observe` / `tap`: **"Allow 'DeviceAutomator' to access Xcode?"** — ask the user to click **Allow**. It is scoped to the daemon process, not the code signature, so it should not reappear on every reconnect. It can reappear after a daemon restart (including a Device Automator rebuild).

6. **Verify.** These succeed without DeviceInteraction: `list_targets`, `get_target`, `list_devices`, `screenshot`. Then `observe` (the dialog from step 5 appears on first use). Search the `.txt` at `hierarchyPath` for `Application, pid:` and the screen's labels.

If the app needs a paired watch:

```bash
xcrun simctl pair <watch-udid> <phone-udid>
xcrun simctl pair_activate <pair-udid>
xcrun simctl boot <watch-udid>
```

### Rebuilding Device Automator itself

`scripts/run-mcp.sh` installs a re-signed copy to `~/Library/Application Support/DeviceAutomator/bin/DeviceAutomator` when that file is missing, or when the newest Release build under `~/Library/Developer/Xcode/DerivedData/DeviceAutomator-*` is newer than it. Otherwise the installed copy is exec'd as-is. So after a Release rebuild, relaunching MCP picks it up; to force a reinstall, delete the installed binary and relaunch MCP.

`--self-test` on the binary runs identifier / observe-normalization checks (no Xcode).

## Register the MCP server

Every client needs the same three facts: a server name, `command: /bin/bash`, and `args: ["<absolute path to scripts/run-mcp.sh>"]`. Keep the script path in `args`, not in `command`: some clients split `command` on spaces, and the checkout path may contain one. Paths must be absolute and specific to this Mac.

Generic `mcpServers` JSON (`mcp.example.json`):

```json
{
  "mcpServers": {
    "device-automator": {
      "command": "/bin/bash",
      "args": ["/ABSOLUTE/PATH/TO/Device-Automator/scripts/run-mcp.sh"]
    }
  }
}
```

Client-specific shortcuts:

| Client | How |
| --- | --- |
| Claude Code | `claude mcp add device-automator -- /bin/bash "/ABSOLUTE/PATH/TO/Device-Automator/scripts/run-mcp.sh"` |
| Cursor | Put the JSON above in `~/.cursor/mcp.json` (or `.cursor/mcp.json` in a project). |
| Codex CLI | `~/.codex/config.toml`: `[mcp_servers.device-automator]`, `command = "/bin/bash"`, `args = ["/ABSOLUTE/PATH/…/run-mcp.sh"]` |
| Anything else | Use the JSON block, or the client's "add stdio MCP server" UI with the same command and args. |

Reload MCP after registering. Prefer **one** registration (user *or* project, not both). Two registrations still share one daemon; they must not each start a session.

Manual smoke test (proxy only; the daemon stays in the background):

```bash
/bin/bash "/ABSOLUTE/PATH/TO/Device-Automator/scripts/run-mcp.sh"
```

## Configure the target app

A missing `config.json` starts empty. Call `add_target` then `set_target` before `observe`. `add_target` parameters are `snake_case`; `config.json` fields are `camelCase`.

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

Prefer an **iOS 27** simulator UDID. Or edit `~/Library/Application Support/DeviceAutomator/config.json` directly (see `config.example.json`; override the path with `DEVICE_AUTOMATOR_CONFIG`):

| `config.json` (camelCase) | `add_target` (snake_case) | Meaning |
| --- | --- | --- |
| `name` | `name` | Short name, e.g. `MyApp` |
| `projectPath` | `project_path` | Absolute `.xcodeproj` or `.xcworkspace` |
| `scheme` | `scheme` | Xcode scheme |
| `bundleId` | `bundle_id` | App bundle identifier |
| `device` | `device` | Simulator UDID |

## Drive loop

Do this without asking, in one MCP connection:

1. `get_target` — confirm app, scheme, bundle id, device.
2. `boot_simulator` if the device is not booted (`list_devices` for a UDID).
3. `install_and_run` after a code change (or once at the start if the binary is stale).
4. `observe` — search/read **only the `.txt` at `hierarchyPath`**. Ignore `screenshotPath`. Tap `hitPoint`s from matching tree lines.
5. `tap` / `type` / `swipe` / `double_tap` / `press_button` / `shake` as needed, then `observe` again. After every gesture, search the new `hierarchyPath` before doing anything else.
6. After another code change, `install_and_run` again, then `observe` / `tap` on the **same** DeviceInteraction session.
7. Leave the session open. Do not call `end_session` between rebuilds.

Stop and ask a human only for:

- Xcode **Allow External Agents to Use Xcode Tools** (once per Mac).
- The first **"Allow 'DeviceAutomator' to access Xcode?"** dialog (once per daemon process).
- Installing an **iOS 27** simulator runtime, or a codesigning identity, when those are missing.

Never:

- Kill `DeviceAutomator` processes, including `--daemon`.
- Call `mcp_auth` (or your client's reconnect) to "fix" a session. Use `reset_session`, then `observe`.
- Start a second DeviceInteraction session (do not call Xcode `DeviceInteractionStart*` yourself).
- Treat `applicationState: NotRun` as "need `install_and_run`" when `hierarchyPath` exists.
- Open `screenshotPath` / `thumbnailScreenshotPath`, or call `screenshot`, because `observe` returned those paths, to see "if the screen loaded," or to pick a tap target.
- Modify Device Automator source while driving another app.

If MCP returns **Not connected**, reconnecting the stdio proxy (`mcp_auth` in clients that have it) is correct: it only re-attaches to the existing daemon. If a tool returns identifier-in-use, session-not-found, or no session key, call `reset_session` then `observe`. Do not wait 20 seconds and do not kill anything.

Cap UI fix/re-verify at **5** attempts. Same symptom twice with no new evidence: stop and report the hierarchy lines.

## Observe result

`observe` and gesture tools return JSON text with at least:

| Field | Use |
| --- | --- |
| `hierarchyPath` | **Only source of truth.** A `.txt` accessibility dump. Search/read this file. Quote lines. Tap its `hitPoint`s. |
| `applicationState` | `Running` when a live tree was captured. Do not reinstall because of `NotRun` if `hierarchyPath` is set. |
| `screenshotPath` / `thumbnailScreenshotPath` | **Do not open.** Returned for Xcode; not part of the default loop. PNG fallback only after the text procedure below has failed. |
| `logsPath` | Optional device logs. |

## Text-first procedure

Mandatory. After **every** `observe` / `tap` / `type` / `swipe` / `double_tap` / `shake`:

1. Take `hierarchyPath` from the tool JSON. It ends in `-hierarchy.txt`.
2. Grep that file (or read it if short). Do **not** open any `.png` in the same step, even if `screenshotPath` is in the same JSON.
3. Search for the control with `label:` / `identifier:` / `Button` / `Selected` / `Disabled`.
4. Quote the matching line(s). If you will tap, use that line's `hitPoint: {x, y}` as `tap` `x`/`y` — integers are fine (`364.0` → `364`).
5. Decide pass/fail from those lines only (label present, `Selected`, `Disabled`, navigation title, alert text). Put the quoted lines in the report.

### Worked example

`observe` returns:

```json
{
  "hierarchyPath": "/var/folders/…/Device Automator FA002CBC-20_05_31_006-hierarchy.txt",
  "screenshotPath": "/var/folders/…/Device Automator FA002CBC-20_05_31_006-screenshot.png",
  "thumbnailScreenshotPath": "/var/folders/…/Device Automator FA002CBC-20_05_31_006-thumbnailScreenshot.png",
  "applicationState": "Running"
}
```

Search the **`.txt` only**, e.g. `grep -E "label: 'More'|label: 'Home'|identifier: 'ellipsis" "<hierarchyPath>"`. Tree hit:

```
Application, pid: 65720, label: 'MyApp'
StaticText, … label: 'Home', hitPoint: {201.0, 84.0}
Button, {{346.0, 66.0}, {36.0, 36.0}}, identifier: 'ellipsis.circle', label: 'More', hitPoint: {364.0, 84.0}
```

Then `tap` `x: 364` `y: 84`. Report those three lines. **Do not** open either PNG.

Wrong: opening `screenshotPath` "to see the UI," then guessing a tap. `observe` always attaches PNGs; that is not permission to open them.

### A tap that changed nothing: tap the child's hitPoint

Device Automator never dedups, debounces, or caches taps. Every `tap` is sent to Xcode as a fresh touch, including repeats at the same point. If the new hierarchy shows no change, the point you tapped is not hit-testable in the app. Tapping it again will not help.

This often happens with SwiftUI `List` rows built as `Button { HStack { Image; Text; Spacer() } }.buttonStyle(.plain)` with no `.contentShape(Rectangle())`. The row `Button`'s accessibility frame spans the whole row, so its `hitPoint` is the row center. A plain-style button only receives touches on its drawn content, and the row center usually falls in the empty `Spacer()` gap. A person tapping there gets nothing either.

```
Button, {{16.0, 436.0}, {370.0, 52.0}}, label: 'Wave Charge', hitPoint: {201.0, 462.0}      ← row center, dead space
 StaticText, {{68.0, 451.8}, {101.3, 20.3}}, label: 'Wave Charge', hitPoint: {118.7, 462.0}  ← tap this
```

When a row-sized `Button` / `Cell` tap produces no change, tap the `hitPoint` of its `StaticText` or `Image` child instead. Mention the dead zone in your report, because real users hit it too.

Also check that the `hitPoint` is not covered by chrome. After scrolling, a row can sit behind the `NavigationBar` or status bar while its `hitPoint` stays in the tree. Compare its `y` with the `NavigationBar` frame, and scroll the row into the clear area before tapping.

### PNG fallback (only after text failed)

Text has **failed** only when you already searched the `.txt` and still cannot answer the check because:

- no node has a `label` / `identifier` for the control (missing accessibility), or
- the question is color, spacing, overlap, or clipping — nothing in the dump encodes it, or
- the user asked about a visual-only regression.

Then you may open `screenshotPath`. In the same message, state: the search pattern, that it missed, and why pixels are required. Taps still use `hitPoint`s from the tree if any node exists. If the PNG and the tree disagree, **the tree wins** — report the tree lines, not the image.

"Layout," "see if it loaded," and "confirm the screen" are **not** failures of the text. A `NavigationBar` identifier, `StaticText` label, or `Application, pid:` line already answers those.

The `screenshot` **tool** is a CoreDevice connectivity check for runtimes that lack Device Interaction. Do not call it while `observe` works.

## Tools (20)

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
| `tap` with `duration` | Long press: holds the touch for `duration` seconds (e.g. `tap(x: 355, y: 140, duration: 1.0)`). Use it for context menus and hold-to-confirm controls. `swipe` also takes `duration`. `double_tap` does not. |
| `shake` | Simulator only. `simctl spawn <UDID> notifyutil -p com.apple.UIKit.SimulatorShake` (what the old Simulator Shake menu sent), then a new hierarchy. The foreground app gets `motionBegan`/`motionEnded(.motionShake)`. |
| `set_orientation` | `devicectl` first; DeviceInteraction `orientation …` if that fails. |
| `end_session` | Optional close. Next `observe` starts a new identifier. Do not call this between rebuilds. |
| `reset_session` | Same close, intended for a wedged session. Does not kill Device Automator. |

## Recovery

| Symptom | Action |
| --- | --- |
| MCP **Not connected** | Reconnect the client's MCP server (`mcp_auth` where available). The new proxy attaches to the existing daemon. |
| identifier in use / recently used / `IDEStatefulActionError` / no session key / session not found | `reset_session`, then `observe`. Do not kill. Do not wait for a human cooldown. |
| `applicationState: NotRun` but `hierarchyPath` is a live tree | Trust the tree. Do not `install_and_run` for that reason. |
| Tempted to open `screenshotPath` to "see the UI" | Search the `.txt` at `hierarchyPath` instead. PNG only after that search cannot answer. |
| `install_and_run` mentions xcodebuild fallback | Session is still the live one. Continue with `observe`. |
| Allow dialog / no iOS 27 runtime / empty signing identities | Stop and ask the user. |
| Several `DeviceAutomator` PIDs, one `--daemon` | Expected. Do not kill. |
| Need a log | `~/Library/Application Support/DeviceAutomator/engine.log` |

Xcode `XcodeListWindows` returns unquoted `tabIdentifier: windowtab-…, workspacePath: …`. Device Automator parses that. Several Xcode tools return `isError` / "not enabled" without a JSON-RPC error; the daemon treats "not enabled" as a missing tool and "identifier in use" as a burned id (new identifier, not a second start on the same id).

The Allow dialog is Xcode's per-process MCP consent, separate from "Allow External Agents" and from macOS TCC. If Agent Activity fills with stale Inactive rows after daemon restarts, the user can click **Clear**.

## Instructions for the driven app's agent

Add this to the agent instruction file of the app being driven (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules`, or your client's equivalent), **not** to this repo:

```markdown
## Verifying UI changes with Device Automator

Before considering a UI-visible change done, prove it in the iOS Simulator from the **text** accessibility dump:

1. `get_target`, then `install_and_run`. If a DeviceInteraction session is already live this must not start a second one.
2. `observe`. Grep/read **only** the `.txt` at `hierarchyPath` for `label:` / `identifier:` / `Selected` / `Disabled`. Quote the matching lines in your report.
3. `tap` using that line's `hitPoint: {x, y}` (`364.0` → `364`). Coordinates never come from pixels.
4. After every gesture, search the new `hierarchyPath` before doing anything else. "Did the screen load?" is answered by `Application, pid:` / `NavigationBar` / `StaticText` lines.
5. Do not open `screenshotPath` / `thumbnailScreenshotPath` or call `screenshot` unless the `.txt` search cannot answer (no label/identifier, or color/overlap/clipping with no tree field). Say which pattern missed. The tree wins over the image.
6. On failure: fix the app, `install_and_run`, repeat from step 2. Cap at 5 attempts; same symptom twice with no new evidence: stop and report the lines.
7. Leave the session open across rebuilds. Wedged: `reset_session`, then `observe`. Never kill DeviceAutomator. Never modify Device Automator.
8. `applicationState: NotRun` with a live `hierarchyPath` is not a reason to reinstall. A first-use Xcode "Allow" dialog needs a human: stop and ask.
```

## Architecture

### Process data flow

One Xcode DeviceInteraction session is owned by **one daemon per machine**. Every MCP client is a stdio proxy onto that daemon.

```
MCP client (Claude Code, Cursor, Codex, …)
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

`ps` may show several `DeviceAutomator` binaries (one per MCP connection, across clients and registrations). That is expected. Exactly one should have `--daemon`. Proxies must attach; they must not start Xcode sessions.

On first proxy start, the process binds the socket if needed and spawns `--daemon`. Later proxies connect to the same socket. Reconnecting starts a new proxy; the daemon and its Xcode session stay. A newer binary (`0.2.0+`) SIGTERMs a stale daemon of a different version, then starts a new one.

### Tool data flow

All tools run inside the daemon (serialized). They use `get_target`'s current app unless you pass `device`.

**No Xcode session: list / boot / screenshot / cold install**

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

**Live UI: observe / tap / rebuild**

```
observe / tap / double_tap / swipe / type / press_button / shake / set_orientation
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
       the folder name `default` is Xcode's dump slot, not the session id

install_and_run   when the daemon HAS a live session
  → DeviceInteractionInstallAndRun(existing interactionSessionKey)
  → on failure: same xcodebuild + devicectl/simctl path as cold install
  → does NOT StartSession and does NOT replace the live key
```

`end_session` / `reset_session` call Xcode `DeviceInteractionEndSession`, clear the key, keep the daemon and mcpbridge. The next `observe` / `tap` mints a **new** identifier. Prefer leaving the session open. Use `reset_session` when the session is wedged.

### Files on this Mac

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

Writes into a configured target's project tree are refused.
