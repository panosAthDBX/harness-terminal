# Remote-connect fixes: per-host timeout + surfaced failures

- **Date:** 2026-06-09
- **Status:** Approved (design); ready for implementation plan
- **Branch point:** `origin/main` (upstream `robzilla1738/harness-cli`)
- **Delivery:** two independent PRs (A, B), each in its own worktree off `origin/main`

## Background

The GUI "Remote" menu lets a user connect the app to a `HarnessDaemon` on another
machine over an SSH-forwarded Unix socket (`SSHTunnelManager` spawns
`ssh -N -L <local>:<remote> <target>`; the client then speaks the normal IPC protocol
to the forwarded local socket).

Observed failure (diagnosed 2026-06-09 against host `ella`): selecting a remote host in
the UI did nothing visible. Root findings:

1. A **cold** SSH connection to the host can take ~50–60s (host asleep / woken on demand;
   network/mDNS itself is instant). `SSHTunnelManager.endpoint(for:waitTimeout:)` uses a
   hard-coded `10`s timeout, so a cold connect always loses the race and throws
   `SSHTunnelError.notReady`. A warm SSH ControlMaster makes the same connect instant.
2. `SessionCoordinator.connectToRemote` catches the failure, stringifies it, and routes it
   to `noteDaemonError`, which is 8s-throttled, returns silently when there is no key/main
   window, and only ever shows a generic "Reconnecting to HarnessDaemon…" toast. The real
   reason is discarded.
3. `ssh`'s own stderr is sent to `/dev/null` (`spawnTunnel`), so there is no diagnostic
   even when debugging.

`origin/main` already improved this area: `SSHTunnelError` has an `exitedEarly(host:status:)`
case (distinguishes a dead ssh from a slow remote) and `SSHTunnelManager` has dependency-
injection seams (`makeTunnelProcess`, `reachabilityProbe`, added in #88) that let tests drive
the lifecycle without spawning real `ssh`. We build on both.

## Scope

In scope — two fixes, two PRs:

- **PR A — per-host configurable tunnel timeout.** The global default stays `10`s; a host may
  override it.
- **PR B — surface remote-connect failures.** Capture `ssh` stderr, attach it to the error,
  and present it (banner for timeout, modal alert for hard failure) instead of swallowing it.

Out of scope (explicitly not in these PRs):

- The environmental cause (host sleeping / SSH ControlMaster warmth). Mitigated by PR A, not
  fixed in code.
- The blank `let remote = NSMenuItem()` top-level menu item — a separate, already-in-progress
  local fix on the user's branch.
- `applyEndpointSwitch` not opening/fronting a window or attaching a surface on a *successful*
  switch (the "even success can render nothing" gap). Tracked separately; not these PRs.

## PR A — per-host configurable tunnel timeout

### Data model
`Packages/HarnessCore/Sources/HarnessCore/Remote/RemoteHostStore.swift`, `struct RemoteHost`:
add

```swift
/// Per-host override for how long to wait for the SSH tunnel to become reachable.
/// nil → use SSHTunnelManager.defaultConnectTimeout.
public var connectTimeoutSeconds: TimeInterval?
```

- Optional, so Swift's synthesized `Codable` uses `encodeIfPresent`/`decodeIfPresent`:
  existing `remote-hosts.json` entries (no key) decode with `nil`, and `nil` is omitted on
  write (no `null` clutter). Back-compat is automatic.
- Add the parameter to the memberwise `init(...)` with `= nil` (keeps existing call sites
  compiling, including tests).

### Tunnel API
`Packages/HarnessCore/Sources/HarnessCore/Remote/SSHTunnelManager.swift`:

- Add `public static let defaultConnectTimeout: TimeInterval = 10`.
- Change `endpoint(for host: RemoteHost, waitTimeout: TimeInterval = 10)` to
  `endpoint(for host: RemoteHost, waitTimeout: TimeInterval? = nil)`.
- Resolve inside the method:
  `let timeout = waitTimeout ?? host.connectTimeoutSeconds ?? Self.defaultConnectTimeout`
  and use `timeout` to build the deadline.
- Rationale: explicit callers (the #88 tests) keep passing a value and are unaffected;
  production caller `RemoteHostsService.connect` omits it and therefore gets the per-host
  value.

### CLI
`Tools/harness/Sources/HarnessCLI/HarnessCLI.swift`, `remote add`:

- Add `--connect-timeout <seconds>`. Validate: parses to a finite number `> 0` and `<= 600`;
  otherwise error with a clear message and exit non-zero. Store into
  `RemoteHost.connectTimeoutSeconds`.
- `remote list` output includes the per-host timeout when set (e.g. `timeout=60s`), and shows
  the default marker when unset.
- `RemoteHostsService` already passes the whole `RemoteHost` through to `endpoint(for:)`, so no
  additional plumbing is required there.

### Tests
- `Tests/HarnessCoreTests/RemoteHostStoreTests.swift`: round-trip a host **with** and
  **without** `connectTimeoutSeconds`; decode a JSON blob that omits the key (asserts
  back-compat → `nil`); assert `nil` is omitted from the encoded JSON.
- `Tests/HarnessCoreTests/SSHTunnelManagerTests.swift`: with an injected `reachabilityProbe`
  that never returns true and an injected long-running `makeTunnelProcess`, call
  `endpoint(for:)` (no explicit `waitTimeout`) on a host whose `connectTimeoutSeconds = 0.3`;
  assert it throws `notReady` and returns in ~0.3–0.5s (proves the host value is honored when
  `waitTimeout` is omitted). A second case passes an explicit `waitTimeout` and asserts it wins
  over the host value.
- CLI parse test (existing `HarnessCLITests` or `RemoteHostStoreTests`): `remote add … --connect-timeout 60`
  persists `connectTimeoutSeconds == 60`; an invalid value (`0`, negative, non-numeric, `> 600`)
  errors.

## PR B — surface remote-connect failures

### Capture ssh stderr
`SSHTunnelManager.spawnTunnel`:

- Replace `process.standardError = FileHandle.nullDevice` with a `Pipe`. Drain it via
  `fileHandleForReading.readabilityHandler` into a small per-tunnel buffer (lock-guarded,
  capped at ~1 KB, keep the tail) so the pipe never blocks ssh and we don't leak fds. Clear the
  handler in `stop`/`stopAll`. `standardOutput` stays `nullDevice`.
- Store the buffer on the `Tunnel` object (guarded by the existing `lock`).

### Error payload
`SSHTunnelError`:

- Extend the failure cases to carry the captured stderr tail:
  `exitedEarly(host:status:stderr:)` and `notReady(host:stderr:)` (stderr is `String`, possibly
  empty). `launchFailed(String)` already carries a message.
- `description` appends the ssh stderr lines when non-empty (e.g.
  `… — ssh said: <captured>`), so the surfaced message names the real cause
  (Permission denied / Could not resolve hostname / bind: Address already in use, etc.).
- Update the throw sites in `endpoint(for:)` to snapshot the buffer and pass it in.

### Carry across the actor hop
`Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift`, `connectToRemote`:

- The caught `Error` is not `Sendable`. Off-main, map it into a `Sendable` value:

```swift
struct RemoteConnectFailure: Sendable {
    enum Kind { case timeout, hard }
    let kind: Kind
    let message: String
}
```

- `static func classifyRemoteConnectError(_ error: Error) -> RemoteConnectFailure` (pure,
  unit-testable):
  - `SSHTunnelError.notReady` → `.timeout`
  - `SSHTunnelError.exitedEarly`, `.launchFailed`, `.invalidConfiguration` → `.hard`
  - any other error → `.hard`
  - `message` = the error's `description` (which already includes the ssh stderr tail).

### Presentation (main actor)
- `.timeout` → a **non-throttled banner** showing `message` (reuse `Toast.show`, but a path
  distinct from the throttled "Reconnecting…" notice, with the real text).
- `.hard` → a modal `NSAlert` showing `message` (works even with no key/main window via
  `runModal`).
- If `.timeout` has no window to host the banner, fall back to an `NSAlert` rather than
  dropping it. In all cases also `fputs` the failure to `harnessStderr` for the diagnostic
  trail.
- `noteDaemonError` and its throttled "Reconnecting…" toast are unchanged and remain for the
  generic daemon-unreachable path; only the explicit remote-connect failure path is rerouted.

### Tests
- `Tests/HarnessCoreTests/SSHTunnelManagerTests.swift`: injected `makeTunnelProcess` returns a
  short script (e.g. `/bin/sh -c 'echo "Permission denied (publickey)." >&2; exit 255'`); assert
  the thrown `exitedEarly.description` contains "Permission denied". A second case: injected
  process stays running, `reachabilityProbe` never true, tiny timeout, writes a line to stderr →
  `notReady` whose `description` contains that line.
- `classifyRemoteConnectError` mapping table test (notReady→timeout; exitedEarly/launchFailed/
  invalidConfiguration→hard; message contains the ssh text).
- The AppKit `NSAlert`/`Toast` presentation is not unit-tested (UI side effect); we test the
  classification and the constructed message only.

## Branch / PR mechanics

- Fetch `origin`, create two worktrees off `origin/main` (one per PR). The user's current dirty
  working tree (`local/all-panos-prs-build` with WIP edits) is untouched.
- Branch names: `feat/per-host-connect-timeout` (A), `fix/surface-remote-connect-failures` (B).
- Both PRs target `robzilla1738/harness-cli` `main`.
- Minor overlap: both edit `SSHTunnelManager.swift` but different regions (A: `endpoint`
  signature + a static constant; B: `spawnTunnel` stderr + the error enum cases + throw sites).
  Whichever merges second takes a trivial rebase. PRs are otherwise independent.
- This spec lives under `docs/superpowers/` and stays fork-local — it is not committed to the
  upstream PR branches.

## Risks / notes

- **Pipe drain:** the stderr `readabilityHandler` must be installed before `process.run()` and
  cleared on stop, and the buffer capped, to avoid blocking ssh or leaking the read fd.
- **Sendable boundary:** only the `RemoteConnectFailure` value (not the `Error`) crosses to the
  main actor; classification happens off-main.
- **Default unchanged:** the global default remains `10`s by explicit decision; only hosts with
  an override wait longer (e.g. `ella` → 60s).
