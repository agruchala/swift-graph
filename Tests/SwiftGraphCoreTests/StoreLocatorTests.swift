import XCTest
@testable import SwiftGraphCore

final class StoreLocatorTests: XCTestCase {
  var tmp: URL!
  var repo: URL!
  let fm = FileManager.default

  override func setUpWithError() throws {
    tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    repo = tmp.appendingPathComponent("Foo")
    try fm.createDirectory(at: repo, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws { try? fm.removeItem(at: tmp) }

  func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }

  func makeStore(_ url: URL) throws { try mkdir(url.appendingPathComponent("v5/units")) }

  func emptyDerivedData() throws -> URL {
    let dd = tmp.appendingPathComponent("DD")
    try mkdir(dd)
    return dd
  }

  func testConfigMissingGivesDefaults() throws {
    XCTAssertEqual(try Config.load(repoRoot: repo), Config())
  }

  func testConfigDecodes() throws {
    try mkdir(repo.appendingPathComponent(".swiftgraph"))
    let json = """
    {"blocklist": ["ThirdPartyKit"], "stores": ["a/store"], "project": "Foo.xcodeproj",
     "schemes": [{"name": "Foo", "destination": "generic/platform=iOS Simulator"}]}
    """
    try json.write(to: repo.appendingPathComponent(".swiftgraph/config.json"), atomically: true, encoding: .utf8)
    var expected = Config()
    expected.blocklist = ["ThirdPartyKit"]
    expected.stores = ["a/store"]
    expected.project = "Foo.xcodeproj"
    expected.schemes = [.init(name: "Foo", destination: "generic/platform=iOS Simulator")]
    XCTAssertEqual(try Config.load(repoRoot: repo), expected)
  }

  func testPartialConfigDecodes() throws {
    try mkdir(repo.appendingPathComponent(".swiftgraph"))
    try #"{"blocklist": ["X"]}"#.write(to: repo.appendingPathComponent(".swiftgraph/config.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(try Config.load(repoRoot: repo).blocklist, ["X"])
  }

  func testFindsDerivedDataByWorkspacePath() throws {
    let dd = try emptyDerivedData()
    for (dir, ws) in [("Foo-abc", repo.path + "/Foo.xcodeproj"), ("Foo-def", repo.path + "-other/Foo.xcodeproj")] {
      try makeStore(dd.appendingPathComponent("\(dir)/Index.noindex/DataStore"))
      let plist = try PropertyListSerialization.data(fromPropertyList: ["WorkspacePath": ws], format: .xml, options: 0)
      try plist.write(to: dd.appendingPathComponent("\(dir)/info.plist"))
    }
    XCTAssertEqual(StoreLocator.find(repoRoot: repo, config: Config(), derivedDataRoot: dd),
                   [dd.appendingPathComponent("Foo-abc/Index.noindex/DataStore").path])
  }

  func testFindsSwiftPMStore() throws {
    let store = repo.appendingPathComponent("Pkg/.build/index-build/arm64-apple-macosx/debug/index/store")
    try makeStore(store)
    XCTAssertEqual(StoreLocator.find(repoRoot: repo, config: Config(), derivedDataRoot: try emptyDerivedData()), [store.path])
  }

  func testFindsSwiftBuildStore() throws {
    let store = repo.appendingPathComponent(".build/out")
    try makeStore(store)
    XCTAssertEqual(StoreLocator.find(repoRoot: repo, config: Config(), derivedDataRoot: try emptyDerivedData()), [store.path])
  }

  func testFindsLocalDerivedData() throws {
    let store = repo.appendingPathComponent(".swiftgraph/DerivedData/Index.noindex/DataStore")
    try makeStore(store)
    XCTAssertEqual(StoreLocator.find(repoRoot: repo, config: Config(), derivedDataRoot: try emptyDerivedData()), [store.path])
  }

  func testExplicitStoresWin() throws {
    try makeStore(repo.appendingPathComponent(".build/out"))
    var c = Config()
    c.stores = ["x/store"]
    XCTAssertEqual(StoreLocator.find(repoRoot: repo, config: c, derivedDataRoot: try emptyDerivedData()),
                   [repo.appendingPathComponent("x/store").path])
  }
}
