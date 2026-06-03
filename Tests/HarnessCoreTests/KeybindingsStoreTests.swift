import XCTest
@testable import HarnessCore

final class KeybindingsStoreTests: XCTestCase {
    private func withTemporaryHarnessHome(_ body: (URL) throws -> Void) throws {
        let previousHome = getenv("HARNESS_HOME").map { String(cString: $0) }
        let root = URL(fileURLWithPath: "/tmp/harness-keybindings-\(UUID().uuidString.prefix(8))", isDirectory: true)
        setenv("HARNESS_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("HARNESS_HOME", previousHome, 1) } else { unsetenv("HARNESS_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        try body(root)
    }

    func testCorruptKeybindingsAreBackedUpNotOverwritten() throws {
        try withTemporaryHarnessHome { _ in
            try HarnessPaths.ensureDirectories()
            let url = KeybindingsStore.fileURL
            try Data("{ not valid keybindings json ".utf8).write(to: url)

            // Unreadable file: load() returns the default tables and preserves the bad file as
            // `.corrupt` rather than silently overwriting the user's bindings with defaults.
            let loaded = KeybindingsStore.load()
            XCTAssertFalse(loaded.tableList.isEmpty, "defaults are returned when the file can't decode")

            let backup = url.appendingPathExtension("corrupt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "the unreadable file is renamed .corrupt")
            XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "{ not valid keybindings json ")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "load() must not rewrite the original over the corrupt file")
        }
    }

    func testAbsentKeybindingsFileSeedsDefaults() throws {
        try withTemporaryHarnessHome { _ in
            // No file present at all → defaults are returned and best-effort seeded (this is the
            // normal first-run path and must NOT produce a `.corrupt` backup).
            let loaded = KeybindingsStore.load()
            XCTAssertFalse(loaded.tableList.isEmpty)
            let backup = KeybindingsStore.fileURL.appendingPathExtension("corrupt")
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    func testStoredShippedPrefixDefaultsMigrateToSessionNavigation() throws {
        try withTemporaryHarnessHome { _ in
            var stored = KeyTableSet.defaults
            stored.setBinding(table: .prefix, binding: Binding(spec: KeySpec(key: "n"), command: .nextWindow, note: "Next tab"))
            stored.setBinding(table: .prefix, binding: Binding(spec: KeySpec(key: "p"), command: .previousWindow, note: "Previous tab"))
            for index in 0 ... 9 {
                stored.setBinding(
                    table: .prefix,
                    binding: Binding(spec: KeySpec(key: String(index)), command: .selectWorkspace(index: index), note: "Workspace \(index)")
                )
            }
            try KeybindingsStore.save(stored)

            let loaded = KeybindingsStore.load()
            let prefix = try XCTUnwrap(loaded.table(.prefix))
            XCTAssertEqual(prefix.lookup(KeySpec(key: "n"))?.command, .nextSession)
            XCTAssertEqual(prefix.lookup(KeySpec(key: "p"))?.command, .previousSession)
            for index in 0 ... 9 {
                XCTAssertEqual(prefix.lookup(KeySpec(key: String(index)))?.command, .selectSession(index: index))
            }
        }
    }

    func testCustomPrefixBindingsAreNotMigrated() throws {
        try withTemporaryHarnessHome { _ in
            var stored = KeyTableSet.defaults
            stored.setBinding(table: .prefix, binding: Binding(spec: KeySpec(key: "n"), command: .nextWindow, note: "Custom next tab"))
            try KeybindingsStore.save(stored)

            let loaded = KeybindingsStore.load()
            XCTAssertEqual(loaded.table(.prefix)?.lookup(KeySpec(key: "n"))?.command, .nextWindow)
            XCTAssertEqual(loaded.table(.prefix)?.lookup(KeySpec(key: "n"))?.note, "Custom next tab")
        }
    }
}
