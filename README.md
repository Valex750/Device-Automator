# Device Automator

A macOS MCP server that lets a coding agent boot a simulator, install an iOS app, and tap through it like a person. It never writes into the driven app’s source tree.

Targets (project path, scheme, bundle ID, device) live in Device Automator config, not in the app you are driving.

## Requirements

- Apple Silicon Mac
- Xcode 27 with the **iOS 27** simulator runtime
- A coding agent that can launch an MCP stdio server (Cursor or Claude Code)
- Xcode Intelligence → **Allow external agents**, then `xcrun mcp-server status` should report permission enabled

Device Interaction (observe, tap, type, swipe) only works on **iOS 27** simulators. Older runtimes can still be listed, booted, and screenshotted.

If the app needs a paired watch, pair a **watchOS 27** simulator with that phone:

```bash
xcrun simctl pair <watch-udid> <phone-udid>
xcrun simctl pair_activate <pair-udid>
xcrun simctl boot <watch-udid>
```

## Install

Build it on the Mac that will run it. Do not copy a `DeviceAutomator` binary from another machine — macOS kills that copy as an invalid code signature.

```bash
git clone https://github.com/Valex750/Device-Automator.git
cd Device-Automator/DeviceAutomator
xcodebuild -project DeviceAutomator.xcodeproj -scheme DeviceAutomator \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
```

If `xcodebuild` fails on signing, either set the target’s Development Team in Xcode or build ad-hoc:

```bash
xcodebuild -project DeviceAutomator.xcodeproj -scheme DeviceAutomator \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- build
```

The MCP launcher installs a re-signed copy to:

`~/Library/Application Support/DeviceAutomator/bin/DeviceAutomator`

It re-signs with a real certificate (`SIGNING_IDENTITY` in `scripts/run-mcp.sh`), not ad-hoc — see [Signing](#signing) below.

## Run

The server speaks MCP on stdin/stdout. Agents should launch it through `scripts/run-mcp.sh`.

Use `/bin/bash` as `command` and the script path as `args`. Do not put the repo path in `command` — MCP clients split `command` on spaces, and this folder name contains a space.

First spawn builds Release if needed, then execs the installed binary.

Manual smoke test:

```bash
/bin/bash "/ABSOLUTE/PATH/TO/Device Automator/scripts/run-mcp.sh"
```

Leave that process in the foreground; the agent owns the stdio session.

## Configure a target app

Config file:

`~/Library/Application Support/DeviceAutomator/config.json`

Override with `DEVICE_AUTOMATOR_CONFIG` if you want a different file.

Seed from `config.example.json`, or call `add_target` from the agent:

| Field | Meaning |
| --- | --- |
| `name` | Short name, e.g. `Lift Planner` |
| `projectPath` | Absolute `.xcodeproj` or `.xcworkspace` |
| `scheme` | Xcode scheme |
| `bundleId` | App bundle identifier |
| `device` | Simulator UDID (`xcrun simctl list devices`) |

`set_target` selects which configured app to drive. Device Automator refuses writes into those project trees (screenshots and derived data go under Application Support).

## Configure Cursor

In the project you want the agent to drive (or in Cursor user MCP settings), add a server. Copy `mcp.example.json` and replace the script path with the clone on that Mac:

```json
{
  "mcpServers": {
    "device-automator": {
      "command": "/bin/bash",
      "args": [
        "/ABSOLUTE/PATH/TO/Device Automator/scripts/run-mcp.sh"
      ]
    }
  }
}
```

Reload MCP. Cursor should list 18 tools. `list_targets`, `list_devices`, and `screenshot` should return without opening Xcode. `observe` / `tap` need Xcode running, the target project opened at least once, and **Allow external agents** for Cursor on that Mac.

## Configure Claude Code

Add the same `mcpServers` block to Claude Code’s user MCP config (or a project `.mcp.json`). Paths must be absolute. Cursor’s “Allow external agents” approval does not apply to Claude Code — approve Claude Code in Xcode separately.

After reload, the agent can:

1. `list_devices` / `boot_simulator`
2. `install_and_run` (build + install + launch; does not edit app source)
3. `observe` for the accessibility tree and `hitPoint`s
4. `tap` / `type` / `swipe` / `press_button`
5. `end_session` when the flow is done

## Troubleshooting

### "Xcode started a device session but returned no session key" / tabIdentifier errors

Xcode's `XcodeListWindows` returns an unquoted, human-readable line like `* tabIdentifier: windowtab-12ta0uNPy1, workspacePath: /path`, not JSON — and several Xcode MCP tools (`XcodeOpenWorkspace`, `XcodeListWorkspaces`, `DeviceInteractionStartWorkspaceSession`) can fail at the IDE level (e.g. "Tool 'X' is not enabled", or an `IDEKit.IDEStatefulActionError`) by returning a normal, non-throwing result rather than a JSON-RPC error. Earlier builds mis-parsed the unquoted format and also treated any non-throwing result as success, which silently skipped the correct fallback tool (`XcodeListWindows`, then `DeviceInteractionStartSession`) and sent Xcode a stale or wrong tab identifier. Both are fixed: `InteractionEngine` now parses the unquoted format and explicitly checks for "not enabled" / missing-session-key responses before falling through.

### "This session identifier is currently in use or was recently used"

Xcode enforces a short cooldown before a `sessionIdentifier` can be reused, even across process restarts. Device Automator used to send the fixed literal `"Device Automator"`, so restarting the process quickly (e.g. right after installing a new build) could collide with the previous process's identifier. It's now scoped per process (`"Device Automator-<pid>"`).

### Confusing or mismatched error text from Xcode MCP calls

The Xcode MCP client didn't check that a response's JSON-RPC `id` matched the request it was replying to, so a late response to an earlier call could be mistaken for the reply to a different, later call — showing up as unrelated error text. Responses are now matched by `id`, discarding anything else.

### "Allow 'DeviceAutomator' to access Xcode?" reappearing often

This is Xcode's own external-agent consent gate (Settings → Intelligence → Model Context Protocol), separate from macOS's classic Automation/TCC prompt, and separate from "Allow External Agents to Use Xcode Tools" (which just permits connections at all — it can be `Always` and you'll still see this dialog). It appears to be scoped to the running process instance rather than to the binary's code signature, so it can reappear whenever the subprocess restarts — which happens on every rebuild-and-reinstall cycle during active development on Device Automator itself. We didn't find a setting or command-line switch to pre-authorize it once per machine. If Xcode's Agent Activity popover (the sparkle icon in the main window's toolbar) accumulates stale/`Inactive` entries from repeated restarts, click **Clear** there.

### Signing

`scripts/run-mcp.sh` re-signs the installed copy with a real certificate (`SIGNING_IDENTITY`, set near the top of the script) instead of ad-hoc (`--sign -`). Ad-hoc signatures get a new hash on every rebuild, which is worse practice in general and gives macOS/Xcode no stable identity to recognize across restarts. Pick any local codesigning identity from `security find-identity -v -p codesigning` and set `SIGNING_IDENTITY` to its name — it does not need to match the identity used to build the app you're driving.

## Tools

| Tool | Role |
| --- | --- |
| `list_targets`, `get_target`, `set_target`, `add_target`, `remove_target` | Named apps to drive |
| `list_devices`, `boot_simulator`, `shutdown_simulator` | Simulators and devices |
| `install_and_run` | Build, install, launch |
| `screenshot` | PNG via CoreDevice |
| `observe` | Screenshot + accessibility tree |
| `tap`, `double_tap`, `swipe`, `type`, `press_button`, `set_orientation` | Human-like input |
| `end_session` | Close the Device Interaction session |

`install_and_run` prefers Xcode Device Interaction and falls back to `xcodebuild` + `devicectl`.
