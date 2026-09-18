# Device Automator

A macOS MCP server that lets a coding agent boot a simulator, install an iOS app, and tap through it like a person. It never writes into the driven app’s source tree.

Targets (project path, scheme, bundle ID, device) live in Device Automator config, not in the app you are driving.

## Agent setup checklist (new Mac, new project)

Written for a coding agent (e.g. Claude Code) setting this up on a Mac and project it hasn't seen before. Follow in order. Step 6 needs a human to click something in a GUI and cannot be scripted or skipped — stop and ask the user there instead of retrying.

1. **Check prerequisites.**
   ```bash
   uname -m                                # expect arm64
   xcodebuild -version                     # expect Xcode 27.x
   xcrun simctl list runtimes | grep -i ios # expect an iOS 27.x runtime
   ```
   `observe` / `tap` / `type` / `swipe` (Device Interaction) only work on an **iOS 27** simulator. Other runtimes still support `list_devices`, `boot_simulator`, and `screenshot`. If there's no iOS 27 runtime, ask the user to install one via Xcode → Settings → Platforms.

2. **Clone and build.**
   ```bash
   git clone https://github.com/Valex750/Device-Automator.git
   cd Device-Automator/DeviceAutomator
   xcodebuild -project DeviceAutomator.xcodeproj -scheme DeviceAutomator \
     -configuration Release -destination 'platform=macOS,arch=arm64' build
   ```
   If signing fails here, append `CODE_SIGN_IDENTITY=-` to that command — that's just the one-off build step; the *installed* copy still gets re-signed with a real identity in the next step.

3. **Pick a stable signing identity for this Mac** and put it in `scripts/run-mcp.sh`.
   ```bash
   security find-identity -v -p codesigning
   ```
   Pick any identity from the output — a free personal "Apple Development" certificate is fine, and it does **not** need to match whatever identity signs the app you'll be driving. Edit the `SIGNING_IDENTITY="..."` line near the top of `scripts/run-mcp.sh` to that exact string. If the list is empty, ask the user to open Xcode → Settings → Accounts and add their Apple ID (Xcode creates a personal certificate automatically), then retry this step.

4. **Register the MCP server** with the coding agent (Claude Code: a project `.mcp.json` or user-level MCP settings), using the absolute path to `scripts/run-mcp.sh` **on this Mac**. The folder name contains a space, so keep it as one quoted string:
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
   Reload MCP servers so it connects, then confirm with `list_targets` that 18 tools are available (see the [Tools](#tools) table).

5. **Configure the target app you actually want to drive.** A fresh checkout seeds `config.json` with a placeholder pointing at the original author's own project (`Lift Planner`), but only when no config exists yet — that placeholder is almost certainly not the app you want on a different Mac. Call `add_target` (its parameters are `snake_case`, unlike the `camelCase` field names stored in `config.json` — see [Configure a target app](#configure-a-target-app)) with the real project's details, then `set_target`:
   ```
   add_target(
     name: "<ShortName>",
     project_path: "/ABSOLUTE/PATH/TO/App.xcodeproj",  # or .xcworkspace
     scheme: "<SchemeName>",
     bundle_id: "com.example.app",
     device: "<UDID from list_devices>"
   )
   set_target(name: "<ShortName>")
   ```
   Get a device UDID with `list_devices` (or `xcrun simctl list devices`) — prefer an **iOS 27** simulator if `observe`/`tap`/`type`/`swipe` will be used.

6. **Two one-time steps only a human can approve.** Ask the user to do these rather than retrying automatically — there is no scriptable or command-line way to pre-authorize either one:
   - In Xcode: **Settings → Intelligence → Model Context Protocol → "Allow External Agents to Use Xcode Tools"** → set to **Always**.
   - The *first* `observe` or `tap` call on this Mac pops a **"Allow '\<binary\>' to access Xcode?"** dialog — Xcode's own per-process agent-consent gate (separate from the setting above, and from macOS's classic Automation/TCC prompt). Ask the user to click **Allow**. It can reappear on later process restarts; see [Troubleshooting](#troubleshooting) if it seems excessive.

7. **Verify.** These should succeed without touching Xcode:
   ```
   list_targets
   get_target
   list_devices
   screenshot
   ```
   `screenshot` here is only a connectivity smoke test (it does not need Xcode). Then try `observe` (expect the one-time dialog from step 6) and confirm `hierarchyPath` covers the app. Drive with its `hitPoint`s — not guessed screenshot pixels. Do not open `screenshotPath` to decide what to tap or whether the UI is correct; if a PNG and the tree disagree, the tree wins. See [Drive from the accessibility tree](#drive-from-the-accessibility-tree).

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

Seed from `config.example.json` directly, or call the `add_target` tool from the agent. Note the two schemas use different casing for the same fields:

| `config.json` field (camelCase) | `add_target` parameter (snake_case) | Meaning |
| --- | --- | --- |
| `name` | `name` | Short name, e.g. `MyApp` |
| `projectPath` | `project_path` | Absolute `.xcodeproj` or `.xcworkspace` |
| `scheme` | `scheme` | Xcode scheme |
| `bundleId` | `bundle_id` | App bundle identifier |
| `device` | `device` | Simulator UDID (`xcrun simctl list devices`) |

`set_target` selects which configured app to drive. Device Automator refuses writes into those project trees (screenshots and derived data go under Application Support).

If `config.json` doesn't exist yet, Device Automator seeds it with one placeholder target (`DefaultTargets.liftPlanner` in `TargetGuard.swift`) pointing at the original author's own project on their Mac. That's a convenience default for that one installation only — on any other Mac or for any other project, call `add_target` and `set_target` for the real app before using `observe`/`tap`/etc., rather than assuming the seeded target is meaningful.

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

Reload MCP. Cursor should list 18 tools. `list_targets`, `list_devices`, and `screenshot` should return without opening Xcode (`screenshot` is a connectivity check, not how you verify UI). `observe` / `tap` need Xcode running, the target project opened at least once, and **Allow external agents** for Cursor on that Mac.

## Configure Claude Code

Add the same `mcpServers` block to Claude Code’s user MCP config (or a project `.mcp.json`). Paths must be absolute. Cursor’s “Allow external agents” approval does not apply to Claude Code — approve Claude Code in Xcode separately.

After reload, the agent can:

1. `list_devices` / `boot_simulator`
2. `install_and_run` (build + install + launch; does not edit app source)
3. `observe` for `hierarchyPath` and `hitPoint`s (source of truth; ignore `screenshotPath` unless the tree cannot answer the check)
4. `tap` / `type` / `swipe` / `press_button`
5. `end_session` when the flow is done

## Drive from the accessibility tree

`observe` (and tap/type/swipe results) return a `hierarchyPath` and a
`screenshotPath`. The hierarchy is the iOS equivalent of a DOM. **Treat the
tree as the only source of truth.** Enforce the tree against screenshots:

1. After every `observe` / `tap` / `type` / `swipe` / `double_tap`, open or
   grep `hierarchyPath` first. Find the control by `label` / `identifier`,
   then tap its `hitPoint`.
2. Confirm behavior from the tree: labels, `Selected` / enabled state,
   presence or absence of nodes, navigation. Quote those lines when reporting
   what was verified.
3. **Do not** open `screenshotPath` or `thumbnailScreenshotPath`. **Do not**
   call the `screenshot` tool to drive or verify UI. Ignore those paths unless
   the exception below applies.
4. If a screenshot and the tree disagree, the tree wins. Report the tree
   evidence, not the image.

**Screenshot exception (narrow).** Open a PNG only when the tree cannot
answer the check: layout, spacing, or color that accessibility does not
expose; a missing accessibility label so the node is not in the tree; or a
visual-only regression the user asked about. Say why the tree was
insufficient. Then still tap `hitPoint`s from the tree, never pixel guesses.

The standalone `screenshot` tool is for connectivity checks on runtimes that
lack Device Interaction, not for verifying features when `observe` works.

## Skill template: full dev cycle

For an agent that will repeatedly plan, implement, build, verify, and fix
features using Device Automator, it's worth creating a reusable skill once
per project rather than re-explaining the workflow each time. In Claude Code,
a skill is a Markdown file with YAML frontmatter at
`.claude/skills/dev-cycle/SKILL.md` **inside the app project being driven**
(not inside this Device Automator checkout), invoked afterward as
`/dev-cycle <feature description>`.

To set this up on a new Mac/project, create that file with this content
verbatim (it's already project-agnostic — no path substitution needed):

````markdown
---
name: dev-cycle
description: Full plan-implement-run-verify-fix loop for developing a feature or fixing a bug in this app, using Device Automator to drive the iOS Simulator like a real user rather than just reading code or screenshots. Use when the user asks to build/implement/add a feature, fix a bug end-to-end, or invokes /dev-cycle <description>.
---

# Feature development cycle (plan → build → verify → fix)

Use this whenever developing a feature or fixing a bug that has a visible UI
effect, and the `device-automator` MCP tools are available. Don't consider the
work done until it's been verified through real Simulator interaction against
the accessibility tree — not just "compiles" or "looks right in a screenshot."
Verification in steps 4–6 follows the `verify-in-simulator` skill: tree first,
screenshots only when the tree cannot answer the check.

## What to build

Treat the request text (or the argument passed to this skill) as the
feature/fix to implement. If scope is ambiguous, ask a clarifying question
before starting rather than guessing.

## The cycle

1. **Plan.** Read the relevant existing code first (views, view models,
   models) and decide the smallest correct change. Call `get_target` to
   confirm you're driving the right app/scheme/device before touching
   anything.
2. **Implement.** Make the change in the app's own source. Never modify
   Device Automator's own source as part of this cycle — it's a separate
   tool; if it misbehaves, stop and tell the user instead of patching it.
3. **Build and launch.** Call `install_and_run` to build, install, and launch
   the app fresh with the change.
4. **Verify like a user.** Follow `verify-in-simulator`: call `observe`, then
   navigate with `tap` / `type` / `swipe` / `double_tap` using `hitPoint`s
   from the latest hierarchy. Confirm text, state, and navigation from the
   tree, including the obvious edge cases (empty state, error state, etc.),
   not just the happy path. Do not open `screenshotPath` unless the tree
   cannot answer the check. If a screenshot and the tree disagree, the tree
   wins.
5. **Fix and re-verify.** If something's wrong, read the error/state from
   the hierarchy, fix the app's source, rebuild with `install_and_run`, and
   repeat step 4. Keep iterating until it's actually correct — don't stop
   at "it should work now" — but obey the hard stop below; do not loop
   indefinitely.
6. **Close out.** Call `end_session` once verified. Summarize what changed
   and how it was verified (quote hierarchy lines, not a screenshot recap).

## Hard stop

Cap step 5 at **5 fix attempts total**. Stop earlier than that if the same
error or symptom repeats twice in a row with no new information — that means
the fix isn't addressing the real cause, not that one more try will help.

When you stop (whether by hitting the cap or stopping early), do not keep
iterating or start guessing wildly. Report to the user: what you tried, the
exact current failure/symptom (quote the hierarchy), and your best
hypothesis for the actual cause. Ask how they want to proceed.

## Rules

- Never guess UI coordinates from screenshot pixels — always use `observe`'s
  `hitPoint`s.
- Never open a screenshot to decide what to tap, whether a screen loaded, or
  whether a feature worked, if the tree already has that information.
- The first `observe`/`tap` call in a session may pop an Xcode "Allow ... to
  access Xcode?" dialog. That needs a human click — tell the user rather than
  retrying it blindly.
- "Done" means verified working through real UI interaction against the
  accessibility tree, not "code compiles" or "the screenshot looked right."
````

Once the file exists, the user (or the agent itself) can invoke it with
`/dev-cycle <feature description>`, or Claude Code may pick it up
automatically for matching requests per its `description`.

## Skill template: verify-in-simulator (for agents that already plan/implement)

If an agent already has its own plan-implement-review workflow and just needs
to know it *can* verify a UI-visible change by actually running it — rather
than stopping at code review or a screenshot guess — give it this narrower
skill instead of (or alongside) `dev-cycle`. It only covers building,
launching, and verifying via `observe`/`tap`, with the same fix/re-verify
loop and hard stop, and skips the planning/implementing steps the calling
agent already handles.

Create `.claude/skills/verify-in-simulator/SKILL.md` **inside the app project
being driven** with this content verbatim:

````markdown
---
name: verify-in-simulator
description: Verify that a UI-visible change actually works by running the app in the iOS Simulator via Device Automator (build, launch, observe, tap), using the accessibility tree as the source of truth rather than screenshots. Use after implementing or fixing a UI-visible change, when asked to confirm/test/verify a feature works, or before considering such a change done.
---

# Verify in Simulator

Use this after a UI-visible change has already been planned, implemented, and
reviewed elsewhere — this skill only covers proving it actually works, using
the `device-automator` MCP tools to drive the app like a real user. It does
not cover planning or implementing; if those haven't happened yet, do them
first (or use the `dev-cycle` skill for the full loop).

## Source of truth: accessibility tree, not screenshots

`observe` (and tap/type/swipe results) return a `hierarchyPath` and a
`screenshotPath`. The hierarchy is the iOS equivalent of a DOM. **Treat the
tree as the only source of truth.** Enforce the tree against screenshots:

1. After every `observe` / `tap` / `type` / `swipe` / `double_tap`, open or
   grep `hierarchyPath` first. Find the control by `label` / `identifier`,
   then tap its `hitPoint`.
2. Confirm behavior from the tree: labels, `Selected` / enabled state,
   presence or absence of nodes, navigation. Quote those lines when you
   report what you verified.
3. **Do not** `Read` `screenshotPath` or `thumbnailScreenshotPath`. **Do not**
   call the `screenshot` tool. Ignore those paths unless the exception below
   applies.
4. If a screenshot and the tree disagree, the tree wins. Report the tree
   evidence, not the image.

**Screenshot exception (narrow).** Open a PNG only when the tree cannot
answer the check: layout, spacing, or color that accessibility does not
expose; a missing accessibility label so the node is not in the tree; or a
visual-only regression the user asked about. Say why the tree was
insufficient. Then still tap `hitPoint`s from the tree, never pixel guesses.

## Steps

1. **Confirm target.** Call `get_target` to confirm you're driving the right
   app/scheme/device before doing anything else.
2. **Build and launch.** Call `install_and_run` to build, install, and launch
   the app fresh with the change under test.
3. **Verify like a user.** Call `observe`, then drive the feature with
   `tap` / `type` / `swipe` / `double_tap` using `hitPoint`s from the latest
   tree. Confirm text, state, and navigation against the hierarchy,
   including the obvious edge cases (empty state, error state, etc.), not
   just the happy path.
4. **Fix and re-verify.** If something's wrong, read the error/state from
   the hierarchy, fix the app's source, rebuild with `install_and_run`, and
   repeat step 3.
5. **Close out.** Call `end_session` once verified. Report what you verified
   and how — quote the relevant hierarchy lines or describe the exact
   interaction sequence, not just "it works" and not a screenshot recap.

## Hard stop

Cap step 4 at **5 fix attempts total**. Stop earlier than that if the same
error or symptom repeats twice in a row with no new information — that means
the fix isn't addressing the real cause, not that one more try will help.

When you stop (whether by hitting the cap or stopping early), do not keep
iterating or start guessing wildly. Report to the user: what you tried, the
exact current failure/symptom (quote the hierarchy), and your best
hypothesis for the actual cause. Ask how they want to proceed.

## Rules

- Never guess UI coordinates from screenshot pixels — always use `observe`'s
  `hitPoint`s.
- Never open a screenshot to decide what to tap, whether a screen loaded, or
  whether a feature worked, if the tree already has that information.
- Never modify Device Automator's own source as part of this skill — it's a
  separate tool; if it misbehaves, stop and tell the user instead of
  patching it.
- The first `observe`/`tap` call in a session may pop an Xcode "Allow ... to
  access Xcode?" dialog. That needs a human click — tell the user rather than
  retrying it blindly.
- "Verified" means confirmed working through real UI interaction against the
  accessibility tree, not "code compiles," "should work," or "the screenshot
  looked right."
````

Skills only get picked up when Claude Code decides the task matches their
`description`, which is a bit less certain for a fully autonomous agent with
loosely-framed tasks than an explicit `/verify-in-simulator` invocation. For a
harder guarantee, add a short standing reminder to that project's own
`CLAUDE.md` (create one if it doesn't have one yet) — this is always loaded,
regardless of skill-matching:

```markdown
## Verifying UI changes

Before considering any UI-visible change done, verify it actually works in
the iOS Simulator using the `device-automator` MCP tools — don't rely on code
review or a screenshot guess alone. Drive and verify from `observe`'s
accessibility tree (`hierarchyPath`); do not open screenshots when the tree
already has the answer. Use the `verify-in-simulator` skill for just the
verification step, or `dev-cycle` for the full plan-implement-verify loop,
rather than stopping at "should work."
```

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
| `screenshot` | PNG via CoreDevice. Connectivity smoke test only; do not use it to drive or verify UI when `observe` is available |
| `observe` | Accessibility tree (`hierarchyPath`) + PNG. Drive and verify from the tree; ignore `screenshotPath` unless the tree cannot answer the check |
| `tap`, `double_tap`, `swipe`, `type`, `press_button`, `set_orientation` | Human-like input |
| `end_session` | Close the Device Interaction session |

`install_and_run` prefers Xcode Device Interaction and falls back to `xcodebuild` + `devicectl`.
