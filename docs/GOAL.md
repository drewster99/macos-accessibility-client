# GOAL: Ship the Mac & Simulator Control MCP server — fully built, tested, and publishable

Build the server specified in [`MCP_DESIGN.md`](./MCP_DESIGN.md), which is the source of
truth. You are **not done** until every item below is demonstrably true *with evidence*
(test output, logs, screenshots, or a recorded run) — never on assumption. Keep iterating
until all gates are green; if something genuinely can't be verified, stop and surface the
specific blocker rather than skipping it.

## Done = all of these, proven

1. **Spikes pass first.** All five P0a de-risk spikes validated on-device: TCC attribution
   lands on the host (not Terminal / the MCP client / the relay); XPC admission rejects an
   unsigned/mismatched caller; observation coverage measured on native + Electron + simulator;
   Screen-Recording relaunch behavior characterized; relay reconnect across host re-exec works.
   If any spike disproves the design, fix the design before building on it.
2. **Everything builds.** Zero errors **and** zero warnings, in Debug and Release, built
   **via xcode-mcp-server** (never `xcodebuild` / `swift build`).
3. **Every tool works.** Each tool in §8 is implemented and exercised end-to-end through a
   real MCP client → relay → host, with a passing assertion — including the generic AX verbs,
   CGEvent input, clipboard, OCR, screenshots (Mac + simulator), and the `simctl` suite.
4. **Tested broadly.** Unit tests for AXKit + journal/quiescence/diff/locator; integration
   tests that drive a **native app, an Electron app (e.g. VS Code), and a booted simulator**
   and confirm correct diffs, settle behavior (no hangs, caps honored), fail-loud stale refs,
   and no clipboard clobbering. All green.
5. **Permissions & security real.** Full flow from a *clean* grant state works; the two TCC
   grants behave; structured permission errors surface correctly; the XPC code-signing
   requirement is enforced (relaxed only under `#if DEBUG`).
6. **Packaged for release.** Signed (Developer ID) + hardened runtime + **notarized**;
   installs as one bundle; on-demand launch via `SMAppService` verified from a clean state;
   the MCP-client config snippet is documented and confirmed working in an actual client.
7. **No loose ends.** No `TODO` / `FIXME` / stub / `xfail` / skipped tests in shipping paths.
   Anything deliberately deferred is listed explicitly with rationale, not silently dropped.

## Reporting rule

Report outcomes faithfully — show failing output when it fails, state any step that was
skipped, and only call something done when it's verified.
