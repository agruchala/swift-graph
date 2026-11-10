import XCTest
@testable import SwiftGraphCore

final class GraphTextTests: XCTestCase {
  let a = Node(id: "aaaaaaaaaaaa", kind: "instanceProperty", module: "Core", name: "Profile.name",
               file: "Sources/Core/Profile.swift", line: 1, isTest: false, isExternal: false, isProtocolRequirement: false)
  let b = Node(id: "bbbbbbbbbbbb", kind: "instanceMethod", module: "AppTests", name: "ViewModelTests.testRename()",
               file: "Tests/AppTests/ViewModelTests.swift", line: 3, isTest: true, isExternal: false, isProtocolRequirement: true)
  let c = Node(id: "cccccccccccc", kind: "constructor", module: "Foundation", name: "Date.init()",
               file: nil, line: nil, isTest: false, isExternal: true, isProtocolRequirement: false)
  var e1: Edge { Edge(from: b.id, to: a.id, kind: .write, file: "Tests/AppTests/ViewModelTests.swift", line: 3, more: 0) }
  var e2: Edge { Edge(from: a.id, to: c.id, kind: .call, file: "Sources/Core/Profile.swift", line: 1, more: 2) }
  let header = Header(commit: "abc", dirty: true, staleFiles: 2)

  func graph(_ nodes: [Node], _ edges: [Edge]) -> Graph {
    Graph(header: header, nodes: Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) }), edges: edges)
  }

  func testRoundTrip() throws {
    let g = graph([a, b, c], [e1, e2])
    let decoded = try GraphText.decode(GraphText.encode(g))
    XCTAssertEqual(decoded.header, g.header)
    XCTAssertEqual(decoded.nodes, g.nodes)
    XCTAssertEqual(Set(decoded.edges), Set(g.edges))
  }

  func testDeterministic() {
    XCTAssertEqual(GraphText.encode(graph([a, b, c], [e1, e2])), GraphText.encode(graph([c, a, b], [e2, e1])))
  }

  func testPathWithSpaces() throws {
    var n = a
    n.file = "My Watch App/Views/A.swift"; n.line = 7
    let d = try GraphText.decode(GraphText.encode(graph([n], [])))
    XCTAssertEqual(d.nodes[n.id]?.file, "My Watch App/Views/A.swift")
    XCTAssertEqual(d.nodes[n.id]?.line, 7)
  }

  func testHeaderLine() {
    XCTAssertEqual(GraphText.encode(graph([], [])).split(separator: "\n").first, "# swiftgraph 1 commit=abc dirty=1 stale=2")
  }

  func testNodeIDStable() {
    let id = nodeID(usr: "s:4Core7ProfileV")
    XCTAssertEqual(id, nodeID(usr: "s:4Core7ProfileV"))
    XCTAssertEqual(id.count, 12)
    XCTAssertTrue(id.allSatisfy { "0123456789abcdef".contains($0) })
  }

  func testDecodeRejectsGarbage() {
    XCTAssertThrowsError(try GraphText.decode("hello"))
  }
}
