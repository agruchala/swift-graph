import XCTest
@testable import SwiftGraphCore

final class ExtractorTests: XCTestCase {
  nonisolated(unsafe) static var cached: Graph?

  func extract(blocklist: Set<String> = [], stores: [String]? = nil) throws -> Graph {
    try Extractor(repoRoot: Fixture.root, storePaths: stores ?? [Fixture.storePath()], blocklist: blocklist).extract()
  }

  var g: Graph {
    get throws {
      if let c = Self.cached { return c }
      let c = try extract()
      Self.cached = c
      return c
    }
  }

  func node(_ name: String, in graph: Graph? = nil) throws -> Node {
    let all = try graph ?? g
    let matches = all.nodes.values.filter { $0.name == name }
    XCTAssertEqual(matches.count, 1, "nodes named \(name): \(matches) of \(all.nodes.values.map(\.name).sorted())")
    return try XCTUnwrap(matches.first)
  }

  func edge(_ from: String, _ to: String, _ kind: EdgeKind, in graph: Graph? = nil) throws -> Edge? {
    let gr = try graph ?? g
    let f = try node(from, in: gr).id, t = try node(to, in: gr).id
    return gr.edges.first { $0.from == f && $0.to == t && $0.kind == kind }
  }

  func testPropertyReadThroughComputedProperty() throws {
    XCTAssertNotNil(try edge("ViewModel.title", "Profile.name", .read))
  }

  func testPropertyWrite() throws {
    XCTAssertNotNil(try edge("ViewModel.rename(_:)", "Profile.name", .write))
  }

  func testProtocolCall() throws {
    XCTAssertNotNil(try edge("ViewModel.persist()", "Store.save(_:)", .call))
    XCTAssertTrue(try node("Store.save(_:)").isProtocolRequirement)
  }

  func testOverrideEdge() throws {
    XCTAssertNotNil(try edge("DiskStore.save(_:)", "Store.save(_:)", .override))
  }

  func testRetroactiveConformanceOverrideEdge() throws {
    XCTAssertNotNil(try edge("Event.stamp", "Stamped.stamp", .override))
    XCTAssertNotNil(try edge("readStamp(_:)", "Stamped.stamp", .read))
  }

  func testClosureAttributedToEnclosingFunction() throws {
    XCTAssertNotNil(try edge("ViewModel.later()", "ViewModel.persist()", .call))
  }

  func testExternalLeaf() throws {
    let gr = try g
    let stamp = try node("ViewModel.stamp()").id
    let targets = gr.edges.filter { $0.from == stamp && $0.kind == .call }.compactMap { gr.nodes[$0.to] }
    XCTAssertTrue(targets.contains { $0.isExternal && $0.module == "Foundation" && $0.file == nil }, "\(targets)")
  }

  func testBlocklistedModuleIsLeaf() throws {
    let gr = try extract(blocklist: ["Vendor"])
    XCTAssertNotNil(try edge("ViewModel.log()", "Vendor.track(_:)", .call, in: gr))
    let track = try node("Vendor.track(_:)", in: gr)
    XCTAssertTrue(track.isExternal)
    XCTAssertFalse(gr.edges.contains { $0.from == track.id })
  }

  func testRecursionEdge() throws {
    XCTAssertNotNil(try edge("ViewModel.loop(_:)", "ViewModel.loop(_:)", .call))
  }

  func testTestModuleFlag() throws {
    XCTAssertTrue(try node("ViewModelTests.testRename()").isTest)
    XCTAssertNotNil(try edge("ViewModelTests.testRename()", "ViewModel.rename(_:)", .call))
  }

  func testRepoRelativePaths() throws {
    let gr = try g
    XCTAssertFalse(gr.nodes.isEmpty)
    for n in gr.nodes.values { XCTAssertFalse(n.file?.hasPrefix("/") ?? false, "\(n)") }
    for e in gr.edges { XCTAssertFalse(e.file.hasPrefix("/"), "\(e)") }
  }

  func testDeterministic() throws {
    XCTAssertEqual(GraphText.encode(try extract()), GraphText.encode(try extract()))
  }

  func testStaleCount() throws {
    let file = Fixture.root.appendingPathComponent("Sources/Core/Profile.swift").path
    let fm = FileManager.default
    let original = try XCTUnwrap(fm.attributesOfItem(atPath: file)[.modificationDate] as? Date)
    defer { try? fm.setAttributes([.modificationDate: original], ofItemAtPath: file) }
    try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file)
    XCTAssertEqual(try extract().header.staleFiles, 1)
  }

  func testDuplicateStoreDeduped() throws {
    let s = try Fixture.storePath()
    XCTAssertEqual(GraphText.encode(try extract(stores: [s, s])), GraphText.encode(try extract(stores: [s])))
  }

  func testSynthesizedInitIsInternal() throws {
    XCTAssertNotNil(try edge("makeTag()", "Tag.init(label:)", .call))
    let n = try node("Tag.init(label:)")
    XCTAssertFalse(n.isExternal)
    XCTAssertEqual(n.file, "Sources/App/Extras.swift")
  }

  func testObservableWriteIsInternal() throws {
    XCTAssertNotNil(try edge("bump(_:)", "Counter.count", .write))
  }

  func testNoExternalsFromOwnModules() throws {
    let own: Set<String> = ["App", "Core", "Vendor", "AppTests"]
    XCTAssertEqual(try g.nodes.values.filter { $0.isExternal && own.contains($0.module) }.map(\.name), [])
  }

  func testImplicitReferencesSkipped() throws {
    // @Observable's expansion calls ObservationRegistrar.withMutation/access implicitly.
    let gr = try g
    let names = Set(gr.edges.compactMap { gr.nodes[$0.to]?.name })
    XCTAssertFalse(names.contains { $0.contains("withMutation") || $0.contains("access(") }, "\(names.sorted())")
  }

  func testUnreferencedImplicitMembersPruned() throws {
    XCTAssertFalse(try g.nodes.values.contains { $0.name == "ViewModelTests.init(invocation:)" })
  }

  func testNoGitRepo() throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let gr = try Extractor(repoRoot: tmp, storePaths: [], blocklist: []).extract()
    XCTAssertEqual(gr.header.commit, "none")
  }
}
