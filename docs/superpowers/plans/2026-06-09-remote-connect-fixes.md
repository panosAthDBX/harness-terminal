# Remote-connect fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make remote-daemon connects (a) honor a per-host SSH-tunnel timeout, and (b) surface real failures in the GUI instead of swallowing them.

**Architecture:** Two independent PRs off `origin/main` (upstream `robzilla1738/harness-cli`), each in its own git worktree. PR A adds an optional `connectTimeoutSeconds` to `RemoteHost`, threads it through `SSHTunnelManager.endpoint(for:waitTimeout:)`, and exposes it via `remote add --connect-timeout`. PR B captures `ssh` stderr in `SSHTunnelManager`, attaches it to the thrown `SSHTunnelError`, and routes `connectToRemote` failures to a banner (timeout) or modal alert (hard fail) instead of the throttled "Reconnecting…" toast.

**Tech Stack:** Swift, SwiftPM (`swift test`), XCTest, AppKit. macOS.

**Branch point:** `origin/main`. **Default timeout stays 10s** (only per-host overrides wait longer). The design spec is `docs/superpowers/specs/2026-06-09-remote-connect-fixes-design.md`.

---

## File Structure

**PR A — `feat/per-host-connect-timeout`**
- Modify: `Packages/HarnessCore/Sources/HarnessCore/Remote/RemoteHostStore.swift` — add `connectTimeoutSeconds` to `RemoteHost`.
- Modify: `Packages/HarnessCore/Sources/HarnessCore/Remote/SSHTunnelManager.swift` — `defaultConnectTimeout` constant + resolve per-host timeout in `endpoint`.
- Modify: `Tools/harness/Sources/HarnessCLI/HarnessCLI.swift` — `--connect-timeout` parse helper, wire into `remote add`, show in `remote list`.
- Test: `Tests/HarnessCoreTests/RemoteHostStoreTests.swift`, `Tests/HarnessCoreTests/SSHTunnelManagerTests.swift`, `Tests/HarnessCLITests/RemoteConnectTimeoutTests.swift` (new).

**PR B — `fix/surface-remote-connect-failures`**
- Modify: `Packages/HarnessCore/Sources/HarnessCore/Remote/SSHTunnelManager.swift` — capture ssh stderr; add `stderr` to `notReady`/`exitedEarly`.
- Modify: `Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift` — `RemoteConnectFailure`, `classifyRemoteConnectError`, present banner/alert.
- Test: `Tests/HarnessCoreTests/SSHTunnelManagerTests.swift` (update + add), `Tests/HarnessAppTests/RemoteConnectFailureTests.swift` (new).

Each PR is self-contained off `origin/main`. Both edit `SSHTunnelManager.swift` but different regions; the second-merged PR takes a trivial rebase.

---

# Part A — per-host configurable tunnel timeout

### Task A0: Create the PR A worktree off origin/main

REQUIRED SUB-SKILL at execution: `superpowers:using-git-worktrees`. Canonical commands:

- [ ] **Step 1: Fetch and create the worktree**

```bash
cd ~/code/harness-cli
git fetch origin
git worktree add -b feat/per-host-connect-timeout ../harness-cli-timeout origin/main
cd ../harness-cli-timeout
```

- [ ] **Step 2: Sanity-build the package once**

Run: `swift build 2>&1 | tail -5`
Expected: builds with no errors (baseline before changes).

---

### Task A1: Add `connectTimeoutSeconds` to `RemoteHost`

**Files:**
- Modify: `Packages/HarnessCore/Sources/HarnessCore/Remote/RemoteHostStore.swift`
- Test: `Tests/HarnessCoreTests/RemoteHostStoreTests.swift`

- [ ] **Step 1: Write the failing tests** — append to `RemoteHostStoreTests`:

```swift
    func testConnectTimeoutRoundTripsAndIsOmittedWhenNil() throws {
        let store = RemoteHostStore()
        store.upsert(RemoteHost(name: "ella", sshTarget: "u@ella.local",
                                remoteSocketPath: "/Users/u/Library/Application Support/Harness/harness.sock",
                                connectTimeoutSeconds: 60))
        store.upsert(RemoteHost(name: "plain", sshTarget: "u@plain",
                                remoteSocketPath: "/tmp/x.sock"))
        XCTAssertEqual(store.host(named: "ella")?.connectTimeoutSeconds, 60)
        XCTAssertNil(store.host(named: "plain")?.connectTimeoutSeconds)

        // nil must not be serialized as an explicit key (no `null` clutter, clean diffs).
        let json = String(decoding: try Data(contentsOf: HarnessPaths.remoteHostsURL), as: UTF8.self)
        XCTAssertTrue(json.contains("\"connectTimeoutSeconds\" : 60"))
        XCTAssertFalse(json.contains("null"))
    }

    func testLegacyJSONWithoutTimeoutDecodesAsNil() throws {
        // A pre-existing remote-hosts.json (no connectTimeoutSeconds key) must still load.
        let legacy = """
        [{"name":"old","sshTarget":"u@old","remoteSocketPath":"/tmp/o.sock","sshArgs":[]}]
        """
        try HarnessPaths.ensureDirectories()
        try Data(legacy.utf8).write(to: HarnessPaths.remoteHostsURL)
        let host = RemoteHostStore().host(named: "old")
        XCTAssertNotNil(host)
        XCTAssertNil(host?.connectTimeoutSeconds)
    }
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter "RemoteHostStoreTests/(testConnectTimeoutRoundTripsAndIsOmittedWhenNil|testLegacyJSONWithoutTimeoutDecodesAsNil)"`
Expected: FAIL — `RemoteHost` has no `connectTimeoutSeconds` (does not compile).

- [ ] **Step 3: Add the property** — in `struct RemoteHost`, after `public var sshArgs: [String]`:

```swift
    /// Per-host override for how long `SSHTunnelManager.endpoint(for:)` waits for the SSH tunnel to
    /// become reachable. nil → `SSHTunnelManager.defaultConnectTimeout`. Optional so the synthesized
    /// Codable omits it when nil (clean diffs) and decodes pre-existing entries that lack the key.
    public var connectTimeoutSeconds: TimeInterval?
```

And extend the memberwise `init` (add the last parameter, defaulted, plus the assignment):

```swift
    public init(name: String, sshTarget: String, remoteSocketPath: String, sshArgs: [String] = [],
                connectTimeoutSeconds: TimeInterval? = nil) {
        self.name = name
        self.sshTarget = sshTarget
        self.remoteSocketPath = remoteSocketPath
        self.sshArgs = sshArgs
        self.connectTimeoutSeconds = connectTimeoutSeconds
    }
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test --filter "RemoteHostStoreTests/(testConnectTimeoutRoundTripsAndIsOmittedWhenNil|testLegacyJSONWithoutTimeoutDecodesAsNil)"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/HarnessCore/Sources/HarnessCore/Remote/RemoteHostStore.swift Tests/HarnessCoreTests/RemoteHostStoreTests.swift
git commit -m "feat(remote): add optional per-host connectTimeoutSeconds to RemoteHost"
```

---

### Task A2: Thread the per-host timeout through `endpoint(for:)`

**Files:**
- Modify: `Packages/HarnessCore/Sources/HarnessCore/Remote/SSHTunnelManager.swift`
- Test: `Tests/HarnessCoreTests/SSHTunnelManagerTests.swift`

- [ ] **Step 1: Write the failing tests** — append to `SSHTunnelManagerTests`:

```swift
    func testEndpointUsesPerHostTimeoutWhenWaitTimeoutOmitted() {
        let manager = SSHTunnelManager(
            makeTunnelProcess: longRunningProcessFactory(),
            reachabilityProbe: { _ in false })   // never reachable → must time out
        defer { manager.stopAll() }
        var h = host()
        h.connectTimeoutSeconds = 0.3
        let start = Date()
        XCTAssertThrowsError(try manager.endpoint(for: h)) { error in   // no explicit waitTimeout
            guard case SSHTunnelError.notReady = error else { return XCTFail("expected notReady, got \(error)") }
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.3)
        XCTAssertLessThan(elapsed, 3, "must honor the 0.3s per-host timeout, not the 10s default")
    }

    func testExplicitWaitTimeoutOverridesPerHostValue() {
        let manager = SSHTunnelManager(
            makeTunnelProcess: longRunningProcessFactory(),
            reachabilityProbe: { _ in false })
        defer { manager.stopAll() }
        var h = host()
        h.connectTimeoutSeconds = 30   // would be slow if it won
        let start = Date()
        XCTAssertThrowsError(try manager.endpoint(for: h, waitTimeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "explicit waitTimeout must win over per-host")
    }
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter "SSHTunnelManagerTests/(testEndpointUsesPerHostTimeoutWhenWaitTimeoutOmitted|testExplicitWaitTimeoutOverridesPerHostValue)"`
Expected: FAIL — `endpoint(for:)` does not yet read `host.connectTimeoutSeconds` / signature mismatch.

- [ ] **Step 3: Implement** — in `SSHTunnelManager`, add the constant just under `public static let shared = SSHTunnelManager()`:

```swift
    /// Default SSH-tunnel readiness timeout when neither the caller nor the host overrides it.
    public static let defaultConnectTimeout: TimeInterval = 10
```

Change the `endpoint` signature and resolve the timeout at the top of the method body:

```swift
    public func endpoint(for host: RemoteHost, waitTimeout: TimeInterval? = nil) throws -> Endpoint {
        let timeout = waitTimeout ?? host.connectTimeoutSeconds ?? Self.defaultConnectTimeout
        let localSocket = HarnessPaths.tunnelSocketURL(forHost: host.name)
        let endpoint = Endpoint.unix(path: localSocket.path)
```

And change the deadline line from `Date().addingTimeInterval(waitTimeout)` to:

```swift
        let deadline = Date().addingTimeInterval(timeout)
```

(Leave the rest of `endpoint` unchanged. Existing tests that pass an explicit `waitTimeout:` still compile — an integer/double literal binds to `TimeInterval?`.)

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test --filter "SSHTunnelManagerTests"`
Expected: PASS (the two new tests + all pre-existing SSHTunnelManager tests still green).

- [ ] **Step 5: Commit**

```bash
git add Packages/HarnessCore/Sources/HarnessCore/Remote/SSHTunnelManager.swift Tests/HarnessCoreTests/SSHTunnelManagerTests.swift
git commit -m "feat(remote): honor per-host connect timeout in SSHTunnelManager.endpoint"
```

---

### Task A3: CLI `--connect-timeout` flag + parse helper

**Files:**
- Modify: `Tools/harness/Sources/HarnessCLI/HarnessCLI.swift`
- Test: `Tests/HarnessCLITests/RemoteConnectTimeoutTests.swift` (create)

- [ ] **Step 1: Write the failing tests** — create `Tests/HarnessCLITests/RemoteConnectTimeoutTests.swift`:

```swift
import XCTest
@testable import HarnessCLI
import HarnessCore

final class RemoteConnectTimeoutTests: XCTestCase {
    private var home: URL!
    private var previousHome: String?

    override func setUpWithError() throws {
        previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("harness-cli-\(UUID().uuidString)", isDirectory: true)
        setenv("HARNESS_HOME", home.path, 1)
        try HarnessPaths.ensureDirectories()
    }

    override func tearDownWithError() throws {
        if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
        try? FileManager.default.removeItem(at: home)
    }

    func testParseConnectTimeout() throws {
        XCTAssertNil(try HarnessCLI.parseConnectTimeout(nil))
        XCTAssertEqual(try HarnessCLI.parseConnectTimeout("60"), 60)
        XCTAssertEqual(try HarnessCLI.parseConnectTimeout("0.5"), 0.5)
        XCTAssertThrowsError(try HarnessCLI.parseConnectTimeout("0"))
        XCTAssertThrowsError(try HarnessCLI.parseConnectTimeout("-5"))
        XCTAssertThrowsError(try HarnessCLI.parseConnectTimeout("abc"))
        XCTAssertThrowsError(try HarnessCLI.parseConnectTimeout("601"))
    }

    func testRemoteAddStoresConnectTimeout() throws {
        let rc = try HarnessCLI.handleRemote(
            ["remote", "add", "--name", "ella", "--ssh", "u@ella.local",
             "--socket", "/Users/u/Library/Application Support/Harness/harness.sock",
             "--connect-timeout", "60"])
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(RemoteHostStore().host(named: "ella")?.connectTimeoutSeconds, 60)
    }

    func testRemoteAddRejectsBadConnectTimeout() throws {
        let rc = try HarnessCLI.handleRemote(
            ["remote", "add", "--name", "x", "--ssh", "u@h", "--socket", "/p", "--connect-timeout", "nope"])
        XCTAssertEqual(rc, 64)
        XCTAssertNil(RemoteHostStore().host(named: "x"), "a rejected add must not persist the host")
    }

    func testRemoteListLineShowsTimeoutOnlyWhenSet() {
        let withT = RemoteHost(name: "ella", sshTarget: "u@e", remoteSocketPath: "/p", connectTimeoutSeconds: 60)
        XCTAssertTrue(HarnessCLI.remoteListLine(for: withT, connected: false).contains("timeout=60s"))
        let noT = RemoteHost(name: "d", sshTarget: "u@d", remoteSocketPath: "/p")
        XCTAssertFalse(HarnessCLI.remoteListLine(for: noT, connected: false).contains("timeout="))
    }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter "RemoteConnectTimeoutTests"`
Expected: FAIL — `parseConnectTimeout` / `remoteListLine` don't exist; `--connect-timeout` not wired.

- [ ] **Step 3: Implement** — in `HarnessCLI`, add the parse helper and list-line formatter (place near `handleRemote`):

```swift
    /// Parse the optional `--connect-timeout <seconds>` value. nil input → nil (use the default).
    /// Throws on a non-positive, non-finite, non-numeric, or out-of-range (>600s) value.
    static func parseConnectTimeout(_ raw: String?) throws -> TimeInterval? {
        guard let raw else { return nil }
        guard let value = Double(raw), value.isFinite, value > 0, value <= 600 else {
            throw CLIValidationError.invalidConnectTimeout(raw)
        }
        return value
    }

    /// One tab-separated line for `remote list`, appending `timeout=Ns` only when overridden.
    static func remoteListLine(for host: RemoteHost, connected: Bool) -> String {
        var line = "\(host.name)\t\(host.sshTarget)\t\(host.remoteSocketPath)"
        if let t = host.connectTimeoutSeconds { line += "\ttimeout=\(Int(t))s" }
        if connected { line += " [connected]" }
        return line
    }

    enum CLIValidationError: Error, CustomStringConvertible {
        case invalidConnectTimeout(String)
        var description: String {
            switch self {
            case let .invalidConnectTimeout(raw):
                return "--connect-timeout must be a number of seconds in 1...600 (got '\(raw)')"
            }
        }
    }
```

In `handleRemote`, `case "list"`, replace the print line inside the `for h in hosts` loop with:

```swift
            for h in hosts {
                print(remoteListLine(for: h, connected: SSHTunnelManager.shared.isConnected(h.name)))
            }
```

In `handleRemote`, `case "add"`, parse the flag before the `upsert` and pass it through. After the `--ssh-arg` collecting `while` loop and before `let result = store.upsert(...)`:

```swift
            let connectTimeout: TimeInterval?
            do {
                connectTimeout = try parseConnectTimeout(flagValue(args, flag: "--connect-timeout"))
            } catch {
                fputs("harness-cli remote add: \(error)\n", harnessStderr)
                return 64
            }
            let result = store.upsert(RemoteHost(
                name: name, sshTarget: ssh, remoteSocketPath: socketPath,
                sshArgs: sshArgs, connectTimeoutSeconds: connectTimeout))
```

Update the add usage string to include the new flag:

```swift
                fputs("Usage: harness-cli remote add --name <name> --ssh <user@host> "
                    + "--socket <remote-path> [--ssh-arg <arg> ...] [--connect-timeout <seconds>]\n", harnessStderr)
```

- [ ] **Step 4: Run them and confirm they pass**

Run: `swift test --filter "RemoteConnectTimeoutTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Tools/harness/Sources/HarnessCLI/HarnessCLI.swift Tests/HarnessCLITests/RemoteConnectTimeoutTests.swift
git commit -m "feat(cli): remote add --connect-timeout; show per-host timeout in remote list"
```

---

### Task A4: Open PR A

- [ ] **Step 1: Run the full affected test suites once**

Run: `swift test --filter "RemoteHostStoreTests" && swift test --filter "SSHTunnelManagerTests" && swift test --filter "RemoteConnectTimeoutTests"`
Expected: all PASS.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin feat/per-host-connect-timeout
gh pr create --repo robzilla1738/harness-cli --base main --head feat/per-host-connect-timeout \
  --title "Per-host configurable SSH tunnel timeout" \
  --body "Adds an optional per-host \`connectTimeoutSeconds\` (via \`remote add --connect-timeout\`), threaded through \`SSHTunnelManager.endpoint(for:waitTimeout:)\`. The global default stays 10s; only hosts that set an override wait longer (useful for hosts that need to wake from sleep before SSH completes). Shown in \`remote list\`. Back-compat: the field is optional, so existing remote-hosts.json entries decode unchanged and nil is omitted on write.

This pull request and its description were written by Isaac."
```

Confirm the PR with the user before pushing if pushing is gated.

---

# Part B — surface remote-connect failures

### Task B0: Create the PR B worktree off origin/main

REQUIRED SUB-SKILL at execution: `superpowers:using-git-worktrees`.

- [ ] **Step 1: Create the worktree**

```bash
cd ~/code/harness-cli
git fetch origin
git worktree add -b fix/surface-remote-connect-failures ../harness-cli-surface origin/main
cd ../harness-cli-surface
```

- [ ] **Step 2: Sanity-build**

Run: `swift build 2>&1 | tail -5`
Expected: builds clean.

---

### Task B1: Capture ssh stderr and carry it in `SSHTunnelError`

**Files:**
- Modify: `Packages/HarnessCore/Sources/HarnessCore/Remote/SSHTunnelManager.swift`
- Test: `Tests/HarnessCoreTests/SSHTunnelManagerTests.swift`

- [ ] **Step 1: Update the one existing test that binds the changed case + add new tests.**

In `SSHTunnelManagerTests`, change the pattern in `testSSHExitingImmediatelyBailsEarlyWithExitedError` from:

```swift
            guard case let SSHTunnelError.exitedEarly(host, status) = error else {
```
to:
```swift
            guard case let SSHTunnelError.exitedEarly(host, status, _) = error else {
```

Then append:

```swift
    /// A child that writes a known line to stderr then exits non-zero — models ssh failing on auth.
    private func stderrThenExitFactory(_ message: String, status: Int32) -> (RemoteHost, URL) throws -> Process {
        { _, _ in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "echo \(message) >&2; exit \(status)"]
            return process
        }
    }

    func testExitedEarlyCarriesCapturedSSHStderr() {
        let manager = SSHTunnelManager(
            makeTunnelProcess: stderrThenExitFactory("PermissionDeniedPublickey", status: 7),
            reachabilityProbe: { _ in false })
        XCTAssertThrowsError(try manager.endpoint(for: host(), waitTimeout: 5)) { error in
            guard case let SSHTunnelError.exitedEarly(_, status, stderr) = error else {
                return XCTFail("expected exitedEarly, got \(error)")
            }
            XCTAssertEqual(status, 7)
            XCTAssertTrue(stderr.contains("PermissionDeniedPublickey"), "captured ssh stderr, got: \(stderr)")
            XCTAssertTrue("\(error)".contains("PermissionDeniedPublickey"), "description surfaces ssh stderr")
        }
        XCTAssertFalse(manager.isConnected("devbox"))
    }

    func testNotReadyCarriesCapturedSSHStderr() {
        // Process writes a warning to stderr then stays alive; socket never answers → notReady,
        // but the captured stderr is still surfaced.
        let manager = SSHTunnelManager(
            makeTunnelProcess: { _, _ in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "echo TunnelWarnXYZ >&2; while true; do sleep 1; done"]
                return p
            },
            reachabilityProbe: { _ in false })
        defer { manager.stopAll() }
        XCTAssertThrowsError(try manager.endpoint(for: host(), waitTimeout: 1)) { error in
            guard case let SSHTunnelError.notReady(_, stderr) = error else {
                return XCTFail("expected notReady, got \(error)")
            }
            XCTAssertTrue(stderr.contains("TunnelWarnXYZ"), "captured ssh stderr, got: \(stderr)")
        }
    }
```

- [ ] **Step 2: Run them and confirm they fail**

Run: `swift test --filter "SSHTunnelManagerTests/(testExitedEarlyCarriesCapturedSSHStderr|testNotReadyCarriesCapturedSSHStderr)"`
Expected: FAIL — error cases have no `stderr`; stderr is not captured.

- [ ] **Step 3: Implement — extend the error enum.** Replace the two cases and the matching arms in `SSHTunnelError`:

```swift
    case notReady(host: String, stderr: String)
    case exitedEarly(host: String, status: Int32, stderr: String)
```

```swift
        case let .notReady(host, stderr):
            return "SSH tunnel to '\(host)' did not become ready in time" + Self.sshSuffix(stderr)
        case let .exitedEarly(host, status, stderr):
            return "ssh exited with status \(status) before the tunnel to '\(host)' became ready "
                + "— check the host, credentials, and remote socket path" + Self.sshSuffix(stderr)
```

Add the suffix helper inside `SSHTunnelError`:

```swift
    private static func sshSuffix(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " — ssh said: \(trimmed)"
    }
```

- [ ] **Step 4: Implement — capture stderr on the `Tunnel`.** Replace the `Tunnel` class:

```swift
    private final class Tunnel {
        let process: Process
        let localSocket: URL
        let stderrPipe: Pipe
        private let bufLock = NSLock()
        private var buffer = Data()

        init(process: Process, localSocket: URL, stderrPipe: Pipe) {
            self.process = process
            self.localSocket = localSocket
            self.stderrPipe = stderrPipe
        }

        func appendStderr(_ data: Data) {
            bufLock.lock(); defer { bufLock.unlock() }
            buffer.append(data)
            if buffer.count > 1024 { buffer.removeFirst(buffer.count - 1024) }  // keep the tail
        }

        /// Snapshot the captured stderr. When the process has exited, also drain any unread tail
        /// (EOF makes the read non-blocking); while it's still running we return only what the
        /// readability handler has accumulated so far (a synchronous read would block).
        func stderrText() -> String {
            if !process.isRunning {
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if let tail = try? stderrPipe.fileHandleForReading.readToEnd(), !tail.isEmpty {
                    appendStderr(tail)
                }
            }
            bufLock.lock(); defer { bufLock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }

        func teardown() {
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            try? stderrPipe.fileHandleForReading.close()
        }
    }
```

- [ ] **Step 5: Implement — attach the pipe in `spawnTunnel`.** Replace the body of `spawnTunnel` from `let process = try makeTunnelProcess(...)` through the `tunnels[host.name] = ...` assignment:

```swift
        let process = try makeTunnelProcess(host, localSocket)
        let stderrPipe = Pipe()
        process.standardError = stderrPipe   // override the builder's default; we capture ssh's chatter
        let tunnel = Tunnel(process: process, localSocket: localSocket, stderrPipe: stderrPipe)
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak tunnel] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { tunnel?.appendStderr(data) }
        }

        do {
            try process.run()
        } catch {
            tunnel.teardown()
            throw SSHTunnelError.launchFailed("\(error)")
        }
        lock.lock()
        tunnels[host.name] = tunnel
```

(Keep the `needsCleanupHook`/`atexit` lines that follow unchanged.)

- [ ] **Step 6: Implement — drop the now-redundant stderr line in the default builder.** In `defaultTunnelProcess`, remove the line `process.standardError = FileHandle.nullDevice` (spawnTunnel now owns stderr; keep the `standardOutput = FileHandle.nullDevice` line).

- [ ] **Step 7: Implement — read stderr at the throw sites + teardown.** Add a helper and update `endpoint`/`stop`/`stopAll`.

Helper (in `SSHTunnelManager`):

```swift
    private func capturedStderr(_ name: String) -> String {
        lock.lock(); let tunnel = tunnels[name]; lock.unlock()
        return tunnel?.stderrText() ?? ""
    }
```

In `endpoint`, the early-exit branch becomes:

```swift
            if !running {
                let stderr = capturedStderr(host.name)
                stop(host: host.name)
                throw SSHTunnelError.exitedEarly(host: host.name, status: status ?? -1, stderr: stderr)
            }
```

And the post-loop timeout throw becomes:

```swift
        let stderr = capturedStderr(host.name)
        stop(host: host.name)
        throw SSHTunnelError.notReady(host: host.name, stderr: stderr)
```

In `stop(host:)` and `stopAll()`, call `tunnel.teardown()` before/after terminating — add `tunnel.teardown()` immediately after the `guard let tunnel else { return }` (in `stop`) and inside the `for (_, tunnel) in all` loop (in `stopAll`), before the `if tunnel.process.isRunning` line.

- [ ] **Step 8: Run the tests and confirm they pass**

Run: `swift test --filter "SSHTunnelManagerTests"`
Expected: PASS — new stderr tests green; all pre-existing tests still green (including the updated `exitedEarly` pattern).

- [ ] **Step 9: Commit**

```bash
git add Packages/HarnessCore/Sources/HarnessCore/Remote/SSHTunnelManager.swift Tests/HarnessCoreTests/SSHTunnelManagerTests.swift
git commit -m "feat(remote): capture ssh stderr and surface it in SSHTunnelError"
```

---

### Task B2: Classify the failure for the GUI

**Files:**
- Modify: `Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift`
- Test: `Tests/HarnessAppTests/RemoteConnectFailureTests.swift` (create)

- [ ] **Step 1: Write the failing test** — create `Tests/HarnessAppTests/RemoteConnectFailureTests.swift`:

```swift
import XCTest
@testable import HarnessApp
import HarnessCore

final class RemoteConnectFailureTests: XCTestCase {
    func testNotReadyClassifiesAsTimeout() {
        let f = SessionCoordinator.classifyRemoteConnectError(
            SSHTunnelError.notReady(host: "ella", stderr: "TunnelWarn"))
        XCTAssertEqual(f.kind, .timeout)
        XCTAssertTrue(f.message.contains("ella"))
    }

    func testExitedEarlyClassifiesAsHardAndKeepsSSHStderr() {
        let f = SessionCoordinator.classifyRemoteConnectError(
            SSHTunnelError.exitedEarly(host: "ella", status: 255, stderr: "Permission denied"))
        XCTAssertEqual(f.kind, .hard)
        XCTAssertTrue(f.message.contains("Permission denied"))
    }

    func testLaunchFailedAndInvalidConfigClassifyAsHard() {
        XCTAssertEqual(SessionCoordinator.classifyRemoteConnectError(SSHTunnelError.launchFailed("boom")).kind, .hard)
        XCTAssertEqual(SessionCoordinator.classifyRemoteConnectError(SSHTunnelError.invalidConfiguration("bad")).kind, .hard)
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `swift test --filter "RemoteConnectFailureTests"`
Expected: FAIL — `RemoteConnectFailure` / `classifyRemoteConnectError` don't exist.

- [ ] **Step 3: Implement** — in `SessionCoordinator.swift`, add (near `connectToRemote`):

```swift
    /// A Sendable summary of why a remote connect failed, computed off-main and presented on-main.
    struct RemoteConnectFailure: Sendable {
        enum Kind: Equatable { case timeout, hard }
        let kind: Kind
        let message: String
    }

    /// Map a connect error to a presentation decision. `notReady` (the remote was slow to wake) is a
    /// soft timeout → banner; everything else (bad host/auth/config/launch) is a hard failure → alert.
    /// nonisolated so it can run on the background connect queue.
    nonisolated static func classifyRemoteConnectError(_ error: Error) -> RemoteConnectFailure {
        let message = "\(error)"   // SSHTunnelError's CustomStringConvertible already includes ssh stderr
        if case SSHTunnelError.notReady = error {
            return RemoteConnectFailure(kind: .timeout, message: message)
        }
        return RemoteConnectFailure(kind: .hard, message: message)
    }
```

- [ ] **Step 4: Run it and confirm it passes**

Run: `swift test --filter "RemoteConnectFailureTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift Tests/HarnessAppTests/RemoteConnectFailureTests.swift
git commit -m "feat(app): classify remote-connect failures (timeout vs hard)"
```

---

### Task B3: Present the failure (banner vs alert) in `connectToRemote`

**Files:**
- Modify: `Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift`

This is AppKit UI wiring (no unit test for the modal/banner itself; the decision logic is covered by Task B2). Verify by build.

- [ ] **Step 1: Rewrite `connectToRemote`'s failure branch + add presenters.** Replace the body of `connectToRemote` with:

```swift
    func connectToRemote(named name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var resolved: Endpoint?
            var failure: RemoteConnectFailure?
            do {
                resolved = try RemoteHostsService.shared.connect(named: name)
            } catch {
                failure = SessionCoordinator.classifyRemoteConnectError(error)
            }
            let endpoint = resolved
            let failureValue = failure
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let endpoint {
                        self.applyEndpointSwitch(endpoint)
                    } else if let failureValue {
                        self.presentRemoteConnectFailure(failureValue)
                    }
                }
            }
        }
    }

    /// Surface a remote-connect failure. Timeout → a (longer-hold) banner; hard failure → a modal
    /// alert. Always log to stderr. Never silently drops: if there's no window to host the banner,
    /// fall back to the alert.
    private func presentRemoteConnectFailure(_ failure: RemoteConnectFailure) {
        fputs("Harness: remote connect failed: \(failure.message)\n", harnessStderr)
        switch failure.kind {
        case .timeout:
            if let host = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView {
                Toast.show(failure.message, in: host, hold: 6)
            } else {
                presentRemoteConnectAlert(failure.message)
            }
        case .hard:
            presentRemoteConnectAlert(failure.message)
        }
    }

    private func presentRemoteConnectAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn’t connect to the remote host"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
```

- [ ] **Step 2: Build and run the App-layer tests**

Run: `swift build && swift test --filter "RemoteConnectFailureTests"`
Expected: builds clean; tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Apps/Harness/Sources/HarnessApp/Services/SessionCoordinator.swift
git commit -m "fix(app): surface remote-connect failures (banner on timeout, alert on hard fail)"
```

---

### Task B4: Open PR B

- [ ] **Step 1: Full affected suites green**

Run: `swift test --filter "SSHTunnelManagerTests" && swift test --filter "RemoteConnectFailureTests"`
Expected: all PASS.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin fix/surface-remote-connect-failures
gh pr create --repo robzilla1738/harness-cli --base main --head fix/surface-remote-connect-failures \
  --title "Surface remote-connect failures instead of swallowing them" \
  --body "Selecting a remote host that fails to connect previously showed nothing: ssh stderr went to /dev/null and the error was routed into the throttled, window-gated \"Reconnecting…\" toast. This captures ssh's stderr in \`SSHTunnelManager\` and attaches it to \`SSHTunnelError\` (\`notReady\`/\`exitedEarly\` now carry it), then routes \`connectToRemote\` failures to a banner (timeout) or a modal alert (hard failure: bad host/auth/config), with the real reason. The generic daemon-unreachable toast path is unchanged.

This pull request and its description were written by Isaac."
```

---

## Self-Review

- **Spec coverage:** PR A — data model (A1), API thread-through (A2), CLI flag + list (A3), default-stays-10s (A2 constant). PR B — stderr capture (B1), error payload (B1), Sendable carry + classify (B2), banner/alert present (B3). All spec sections mapped.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `connectTimeoutSeconds: TimeInterval?` used identically in A1/A2/A3; `endpoint(for:waitTimeout:)` is `TimeInterval? = nil` in A2 and all call sites; `SSHTunnelError.exitedEarly(host:status:stderr:)` / `notReady(host:stderr:)` arity matches the updated existing test (B1 Step 1) and the B2 test constructors; `RemoteConnectFailure.Kind` is `Equatable` (used by `XCTAssertEqual` in B2); `classifyRemoteConnectError` is `nonisolated static` (called from the background queue in B3 and from tests in B2); `Toast.show(_:in:hold:)` signature matches B3.
- **Build-order note:** within each PR the tasks are sequential (A1→A2→A3; B1→B2→B3), so each test compiles against code introduced in the same or an earlier task.
