import AppKit
import XCTest
@testable import HarnessApp

@MainActor
final class MainMenuBuilderTests: XCTestCase {
    func testMainMenuIncludesTitledRemoteItem() {
        let menu = MainMenuBuilder.build()
        let remoteItem = menu.items.first { item in item.title == "Remote" }

        XCTAssertNotNil(remoteItem)
        XCTAssertEqual(remoteItem?.submenu?.title, "Remote")
        XCTAssertTrue(remoteItem?.submenu?.delegate === MenuTarget.shared)
    }
}
