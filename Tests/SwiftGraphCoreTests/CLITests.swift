import XCTest
@testable import SwiftGraphCore

final class CLITests: XCTestCase {
  let fm = FileManager.default
  var sg: URL { Fixture.root.appendingPathComponent(".swiftgraph") }

  /// The `swiftgraph` binary built next to this test bundle.
  var binary: URL {
    Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("swiftgraph")
  }

  override func setUpWithError() throws {
    try? fm.removeItem(at: sg)
    _ = try Fixture.storePath()
  }

  override func tearDownWithError() throws { try? fm.removeItem(at: sg) }

  struct Run { var status: Int32; var out: String; var err: String }

  func run(_ args: [String], repo: URL? = nil) throws -> Run {
    let p = Process()
    p.executableURL = binary
    p.arguments = args + ["--repo", (repo ?? Fixture.root).path]
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return Run(status: p.terminationStatus, out: String(decoding: o, as: UTF8.self), err: String(decoding: e, as: UTF8.self))
  }

  func testBootstrapWritesLocalGraph() throws {
    let r = try run(["callers", "Profile.name"])
    XCTAssertEqual(r.status, 0, r.err)
    XCTAssertTrue(r.out.contains("(no graph found; indexed first)"), r.out)
    XCTAssertTrue(r.out.contains("read by ViewModel.title"), r.out)
    XCTAssertTrue(fm.fileExists(atPath: sg.appendingPathComponent("graph.local.txt").path))
    XCTAssertFalse(fm.fileExists(atPath: sg.appendingPathComponent("graph.txt").path))
    XCTAssertTrue(try String(contentsOf: sg.appendingPathComponent(".gitignore"), encoding: .utf8).contains("graph.local.txt"))
  }

  func testCIWritesCommittedGraph() throws {
    let r = try run(["index", "--ci"])
    XCTAssertEqual(r.status, 0, r.err)
    XCTAssertTrue(r.out.hasPrefix("wrote "), r.out)
    XCTAssertTrue(fm.fileExists(atPath: sg.appendingPathComponent("graph.txt").path))
  }

  func testLocalNewerWins() throws {
    try fm.createDirectory(at: sg, withIntermediateDirectories: true)
    try GraphText.encode(Graph(header: Header(commit: "none", dirty: false, staleFiles: 0), nodes: [:], edges: []))
      .write(to: sg.appendingPathComponent("graph.txt"), atomically: true, encoding: .utf8)
    XCTAssertEqual(try run(["index"]).status, 0)
    let r = try run(["find", "Profile"])
    XCTAssertEqual(r.status, 0, r.err + r.out)
    XCTAssertTrue(r.out.contains("Core.Profile"), r.out)
  }

  func testAmbiguousExitCode() throws {
    XCTAssertEqual(try run(["index"]).status, 0)
    let r = try run(["callers", "save"])
    XCTAssertEqual(r.status, 2, r.err)
    XCTAssertTrue(r.out.hasPrefix("ambiguous: 2 matches"), r.out)
  }

  func testUnknownSymbol() throws {
    let r = try run(["callers", "nope"])
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue((r.out + r.err).contains("no symbol matches \"nope\""), r.out + r.err)
  }

  func testNoStoreNoConfig() throws {
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    try sh(["git", "init", "-q"], cwd: tmp)
    let r = try run(["index"], repo: tmp)
    XCTAssertNotEqual(r.status, 0)
    XCTAssertTrue(r.err.contains("add \"project\" and \"schemes\" to .swiftgraph/config.json"), r.err)
  }

  func testEmptyGraphRefused() throws {
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmp.appendingPathComponent(".swiftgraph"), withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    try sh(["git", "init", "-q"], cwd: tmp)
    try #"{"stores": ["\#(try Fixture.storePath())"]}"#
      .write(to: tmp.appendingPathComponent(".swiftgraph/config.json"), atomically: true, encoding: .utf8)
    let r = try run(["index"], repo: tmp)
    XCTAssertNotEqual(r.status, 0)
    XCTAssertTrue(r.err.contains("no indexed Swift files"), r.err)
    XCTAssertFalse(fm.fileExists(atPath: tmp.appendingPathComponent(".swiftgraph/graph.local.txt").path))
  }

  func testNoWarningWhenOnlyNonSwiftCommitsSinceGraph() throws {
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tmp) }
    let git = { (args: [String]) in try sh(["git", "-c", "user.name=t", "-c", "user.email=t@t"] + args, cwd: tmp) }
    try "let a = 1\n".write(to: tmp.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
    try git(["init", "-q"]); try git(["add", "."]); try git(["commit", "-qm", "a"])
    let built = try git(["rev-parse", "HEAD"])
    try "x".write(to: tmp.appendingPathComponent("graph.txt"), atomically: true, encoding: .utf8)
    try git(["add", "."]); try git(["commit", "-qm", "graph"])
    let g = Graph(header: Header(commit: built, dirty: false, staleFiles: 0), nodes: [:], edges: [])
    XCTAssertNil(GraphStore.warning(for: g, repo: tmp))
    try "let a = 2\n".write(to: tmp.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
    try git(["commit", "-qam", "edit"])
    XCTAssertNotNil(GraphStore.warning(for: g, repo: tmp))
  }

  func testStaleWarning() throws {
    var g = Graph(header: Header(commit: "none", dirty: false, staleFiles: 3), nodes: [:], edges: [])
    XCTAssertEqual(GraphStore.warning(for: g, repo: Fixture.root),
                   "! graph built from a stale index (3 files changed since last build); run: swiftgraph index --build")
    g.header.staleFiles = 0
    XCTAssertNil(GraphStore.warning(for: g, repo: Fixture.root))
    g.header.commit = "0123456789abcdef"
    let head = try sh(["git", "rev-parse", "HEAD"], cwd: Fixture.root)
    XCTAssertEqual(GraphStore.warning(for: g, repo: Fixture.root), "! graph built from 0123456, HEAD is \(head.prefix(7))")
  }
}
