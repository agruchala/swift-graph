import XCTest
@testable import SwiftGraphCore

final class FixtureTests: XCTestCase {
  func testStoreExists() throws {
    XCTAssertTrue(FileManager.default.fileExists(atPath: try Fixture.storePath()))
  }
}
