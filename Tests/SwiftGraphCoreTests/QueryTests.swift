import XCTest
@testable import SwiftGraphCore

final class QueryTests: XCTestCase {
  static func n(_ name: String, _ kind: String, _ module: String, _ file: String?, _ line: Int?,
                test: Bool = false, ext: Bool = false, proto: Bool = false) -> Node {
    Node(id: nodeID(usr: name), kind: kind, module: module, name: name, file: file, line: line,
         isTest: test, isExternal: ext, isProtocolRequirement: proto)
  }

  let pname = n("Profile.name", "instanceProperty", "Core", "Core/Profile.swift", 1)
  let save = n("Store.save(_:)", "instanceMethod", "Core", "Core/Profile.swift", 2, proto: true)
  let diskSave = n("DiskStore.save(_:)", "instanceMethod", "Core", "Core/Profile.swift", 3)
  let title = n("ViewModel.title", "instanceProperty", "App", "App/ViewModel.swift", 8)
  let rename = n("ViewModel.rename(_:)", "instanceMethod", "App", "App/ViewModel.swift", 9)
  let persist = n("ViewModel.persist()", "instanceMethod", "App", "App/ViewModel.swift", 10)
  let stamp = n("ViewModel.stamp()", "instanceMethod", "App", "App/ViewModel.swift", 11)
  let loop = n("ViewModel.loop(_:)", "instanceMethod", "App", "App/ViewModel.swift", 14)
  let date = n("Date.init()", "constructor", "Foundation", nil, nil, ext: true)
  let testRename = n("ViewModelTests.testRename()", "instanceMethod", "AppTests", "AppTests/ViewModelTests.swift", 3, test: true)

  func e(_ a: Node, _ b: Node, _ k: EdgeKind, _ file: String, _ line: Int, more: Int = 0) -> Edge {
    Edge(from: a.id, to: b.id, kind: k, file: file, line: line, more: more)
  }

  var graph: Graph {
    let nodes = [pname, save, diskSave, title, rename, persist, stamp, loop, date, testRename]
    return Graph(header: Header(commit: "none", dirty: false, staleFiles: 0),
                 nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }),
                 edges: [
                   e(title, pname, .read, "App/ViewModel.swift", 8),
                   e(rename, pname, .write, "App/ViewModel.swift", 9),
                   e(persist, save, .call, "App/ViewModel.swift", 10, more: 2),
                   e(diskSave, save, .override, "Core/Profile.swift", 3),
                   e(stamp, date, .call, "App/ViewModel.swift", 11),
                   e(loop, loop, .call, "App/ViewModel.swift", 14),
                   e(testRename, rename, .call, "AppTests/ViewModelTests.swift", 3),
                 ])
  }

  var q: Query { Query(graph: graph) }

  func testCallersExactOutput() {
    XCTAssertEqual(q.tree(pname, .callers, QueryOptions()), """
      Profile.name  [instanceProperty]  Core/Profile.swift:1
      ├─ read by ViewModel.title  App/ViewModel.swift:8
      └─ written by ViewModel.rename(_:)  App/ViewModel.swift:9
         └─ called by ViewModelTests.testRename()  AppTests/ViewModelTests.swift:3  [test]

      """)
  }

  func testCalleesShowDefinitionAndCallSite() {
    XCTAssertEqual(q.tree(persist, .callees, QueryOptions()), """
      ViewModel.persist()  [instanceMethod]  App/ViewModel.swift:10
      └─ calls Store.save(_:)  Core/Profile.swift:2  (at :10)  (+2 more)
         └─ DiskStore.save(_:)  Core/Profile.swift:3  via protocol

      """)
  }

  func testCallersOfImplementationIncludeProtocolDispatch() {
    XCTAssertTrue(q.tree(diskSave, .callers, QueryOptions())
      .contains("called by ViewModel.persist()  App/ViewModel.swift:10  (+2 more)  via protocol"))
  }

  func testCallersFollowOverrideChain() {
    let p = Self.n("P.f()", "instanceMethod", "M", "m.swift", 1, proto: true)
    let base = Self.n("Base.f()", "instanceMethod", "M", "m.swift", 2)
    let sub = Self.n("Sub.f()", "instanceMethod", "M", "m.swift", 3)
    let viaP = Self.n("useP()", "function", "M", "m.swift", 4)
    let viaBase = Self.n("useBase()", "function", "M", "m.swift", 5)
    let g = Graph(header: graph.header,
                  nodes: Dictionary(uniqueKeysWithValues: [p, base, sub, viaP, viaBase].map { ($0.id, $0) }),
                  edges: [e(base, p, .override, "m.swift", 2), e(sub, base, .override, "m.swift", 3),
                          e(viaP, p, .call, "m.swift", 4), e(viaBase, base, .call, "m.swift", 5)])
    let out = Query(graph: g).tree(sub, .callers, QueryOptions())
    XCTAssertTrue(out.contains("called by useP()  m.swift:4  via protocol"), out)
    XCTAssertTrue(out.contains("called by useBase()  m.swift:5  via override"), out)
  }

  func testResolveNestedTypeSuffix() {
    let inner = Self.n("Outer.Inner.inBody()", "instanceMethod", "M", "m.swift", 1)
    let g = Graph(header: graph.header, nodes: [inner.id: inner], edges: [])
    guard case .found(let f) = Query(graph: g).resolve("Inner.inBody") else { return XCTFail("not found") }
    XCTAssertEqual(f, inner)
  }

  func testExactNameBeatsSuffixMatch() {
    let exact = Self.n("Entry.timestamp", "instanceProperty", "P", "a.swift", 1)
    let nested = Self.n("SchemaV2.Entry.timestamp", "instanceProperty", "P", "b.swift", 1)
    let g = Graph(header: graph.header, nodes: [exact.id: exact, nested.id: nested], edges: [])
    guard case .found(let f) = Query(graph: g).resolve("Entry.timestamp") else { return XCTFail("not found") }
    XCTAssertEqual(f, exact)
  }

  func testCandidatesCapped() {
    let ns = (0..<35).map { Self.n("T\($0).body", "instanceProperty", "M", "m.swift", $0) }
    let lines = Query.candidates(ns, max: 30).split(separator: "\n")
    XCTAssertEqual(lines.count, 31)
    XCTAssertEqual(lines.last, "… 5 more; qualify with Type.name, Module.Type.name, or an id")
  }

  func testCandidateLineMarksRequirement() {
    XCTAssertTrue(Query.candidateLine(save).hasSuffix("  (protocol requirement)"))
  }

  func testRecursionTerminates() {
    XCTAssertTrue(q.tree(loop, .callers, QueryOptions()).contains("called by ViewModel.loop(_:)  App/ViewModel.swift:14  … (see above)"))
  }

  func testExternalIsLeaf() {
    XCTAssertEqual(q.tree(stamp, .callees, QueryOptions()), """
      ViewModel.stamp()  [instanceMethod]  App/ViewModel.swift:11
      └─ calls Date.init()  [external Foundation]

      """)
  }

  func testUnknownModuleExternal() {
    let main = Self.n("main", "classProperty", "external", nil, nil, ext: true)
    let g = Graph(header: graph.header, nodes: graph.nodes.merging([main.id: main]) { a, _ in a },
                  edges: graph.edges + [e(stamp, main, .read, "App/ViewModel.swift", 11)])
    XCTAssertTrue(Query(graph: g).tree(stamp, .callees, QueryOptions()).contains("reads main  [external]\n"))
  }

  func testExcludedModuleIsLeaf() {
    var o = QueryOptions()
    o.exclude = ["AppTests"]
    XCTAssertTrue(q.tree(rename, .callers, o).contains("called by ViewModelTests.testRename()  AppTests/ViewModelTests.swift:3  [external AppTests]"))
  }

  func testHideTests() {
    var o = QueryOptions()
    o.hideTests = true
    let out = q.tree(pname, .callers, o)
    XCTAssertFalse(out.contains("[test]"))
    XCTAssertFalse(out.contains("testRename"))
  }

  func testLimitCut() throws {
    var o = QueryOptions()
    o.limit = 1
    let last = try XCTUnwrap(q.tree(pname, .callers, o).split(separator: "\n").last)
    XCTAssertEqual(last, "… 2 more nodes cut (raise --depth / --limit)")
  }

  func testDepthCut() throws {
    var o = QueryOptions()
    o.depth = 1
    let out = q.tree(pname, .callers, o)
    XCTAssertFalse(out.contains("testRename"))
    XCTAssertEqual(out.split(separator: "\n").last, "… 1 more nodes cut (raise --depth / --limit)")
  }

  func testAmbiguous() {
    let a = Self.n("A.body", "instanceProperty", "M", "a.swift", 1)
    let b = Self.n("B.body", "instanceProperty", "M", "b.swift", 1)
    let g = Graph(header: Header(commit: "none", dirty: false, staleFiles: 0), nodes: [a.id: a, b.id: b], edges: [])
    guard case .ambiguous(let ns) = Query(graph: g).resolve("body") else { return XCTFail("not ambiguous") }
    XCTAssertEqual(ns.count, 2)
  }

  func testResolveForms() {
    for text in ["Profile.name", "Core.Profile.name", pname.id] {
      guard case .found(let f) = q.resolve(text) else { return XCTFail(text) }
      XCTAssertEqual(f, pname, text)
    }
    for text in ["rename", "rename(_:)", "ViewModel.rename", "App.ViewModel.rename(_:)"] {
      guard case .found(let f) = q.resolve(text) else { return XCTFail(text) }
      XCTAssertEqual(f, rename, text)
    }
    guard case .none = q.resolve("nope") else { return XCTFail("nope") }
  }

  func testFindAndCandidateLine() {
    XCTAssertEqual(q.find("viewmodel.re").map(\.name), ["ViewModel.rename(_:)"])
    XCTAssertEqual(Query.candidateLine(rename), "\(rename.id)  [instanceMethod]  App.ViewModel.rename(_:)  App/ViewModel.swift:9")
    XCTAssertEqual(Query.candidateLine(date), "\(date.id)  [constructor]  Foundation.Date.init()  external")
  }
}
