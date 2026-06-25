import XCTest
import HarnessCore
@testable import HarnessCLI

/// Coverage for the CLI's pure argument-parsing helpers. `harness-cli` previously had no test
/// target at all, so a refactor could silently break flag parsing. `flagValue` is the shared
/// extractor behind ~40 subcommands; its "flag present but no value follows" case (returns nil,
/// which callers treat as "not supplied") is the one the audit flagged as untested.
final class HarnessCLITests: XCTestCase {
    func testFlagValueReturnsTheFollowingToken() {
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "abc"], flag: "--tab"), "abc")
        XCTAssertEqual(HarnessCLI.flagValue(["--cwd", "~", "--tab", "id"], flag: "--tab"), "id")
    }

    func testFlagValueIsNilWhenFlagHasNoValue() {
        // Flag is the final token, so no value follows. Regression guard: this must stay nil (not
        // crash or read past the end), and callers fall back to their usage error.
        XCTAssertNil(HarnessCLI.flagValue(["close-tab", "--tab"], flag: "--tab"))
    }

    func testFlagValueIsNilWhenFlagAbsent() {
        XCTAssertNil(HarnessCLI.flagValue(["--workspace", "Default"], flag: "--tab"))
        XCTAssertNil(HarnessCLI.flagValue([], flag: "--tab"))
    }

    func testFlagValueTakesFirstOccurrence() {
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "first", "--tab", "second"], flag: "--tab"), "first")
    }

    func testFlagValueTakesNextTokenVerbatimEvenIfFlagLike() {
        // Documents current behavior: the token immediately after the flag is taken verbatim, even
        // if it itself looks like a flag — callers validate the value, not flagValue.
        XCTAssertEqual(HarnessCLI.flagValue(["--tab", "--oops"], flag: "--tab"), "--oops")
    }

    func testRemoteAttachTitleUpdateUsesRemoteAgentDisplayName() {
        let localSurface = "68A813BF-596B-4456-BFBD-62A50AFFB72D"
        let remoteAgent = AgentSnapshot(
            kind: .hermes,
            executable: "/Users/remote/.local/bin/hermes",
            pid: 123,
            activity: .working,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        let request = HarnessCLI.remoteAttachTitleUpdateRequest(
            args: ["attach", "--host", "ella", "--surface", "remote-surface"],
            environment: ["HARNESS_SURFACE": localSurface],
            remoteAgentResponse: .agentInfo(remoteAgent)
        )

        guard case let .updateTabTitle(surfaceID, title) = request else {
            return XCTFail("expected updateTabTitle request")
        }
        XCTAssertEqual(surfaceID, localSurface)
        XCTAssertEqual(title, "Hermes")
    }

    func testRemoteAttachTitleUpdateRequiresHostFlag() {
        let remoteAgent = AgentSnapshot(
            kind: .hermes,
            executable: "hermes",
            pid: 123,
            activity: .working,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNil(HarnessCLI.remoteAttachTitleUpdateRequest(
            args: ["attach", "--surface", "remote-surface"],
            environment: ["HARNESS_SURFACE": "local-surface"],
            remoteAgentResponse: .agentInfo(remoteAgent)
        ))
    }

    func testRemoteAttachTitleUpdateRequiresLocalHarnessSurface() {
        let remoteAgent = AgentSnapshot(
            kind: .hermes,
            executable: "hermes",
            pid: 123,
            activity: .working,
            lastActivityAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNil(HarnessCLI.remoteAttachTitleUpdateRequest(
            args: ["attach", "--host", "ella", "--surface", "remote-surface"],
            environment: [:],
            remoteAgentResponse: .agentInfo(remoteAgent)
        ))

        XCTAssertNil(HarnessCLI.remoteAttachTitleUpdateRequest(
            args: ["attach", "--host", "ella", "--surface", "remote-surface"],
            environment: ["HARNESS_SURFACE": ""],
            remoteAgentResponse: .agentInfo(remoteAgent)
        ))
    }

    func testRemoteAttachTitleUpdateRequiresDetectedRemoteAgent() {
        XCTAssertNil(HarnessCLI.remoteAttachTitleUpdateRequest(
            args: ["attach", "--host", "ella", "--surface", "remote-surface"],
            environment: ["HARNESS_SURFACE": "local-surface"],
            remoteAgentResponse: .agentInfo(nil)
        ))

        XCTAssertNil(HarnessCLI.remoteAttachTitleUpdateRequest(
            args: ["attach", "--host", "ella", "--surface", "remote-surface"],
            environment: ["HARNESS_SURFACE": "local-surface"],
            remoteAgentResponse: .error("not found")
        ))
    }
}
