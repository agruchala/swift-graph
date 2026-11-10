import Foundation

public struct GraphTextError: Error, CustomStringConvertible {
  public var line: Int
  public var description: String { "graph.txt: malformed line \(line)" }
}

/// Tab-separated, one record per line, sorted:
///   # swiftgraph 1 commit=<sha|none> dirty=<0|1> stale=<n>
///   N <id> <kind> <module> <name> <file:line|-> <flags|->     flags ⊆ "tpx"
///   E <from> <to> <kind> <file:line> <more>
public enum GraphText {
  public static func encode(_ g: Graph) -> String {
    let h = g.header
    var out = "# swiftgraph \(h.version) commit=\(h.commit) dirty=\(h.dirty ? 1 : 0) stale=\(h.staleFiles)\n"
    for n in g.nodes.values.sorted(by: { $0.id < $1.id }) {
      let loc = n.file.map { "\($0):\(n.line ?? 0)" } ?? "-"
      var flags = ""
      if n.isTest { flags += "t" }
      if n.isProtocolRequirement { flags += "p" }
      if n.isExternal { flags += "x" }
      out += ["N", n.id, n.kind, n.module, n.name, loc, flags.isEmpty ? "-" : flags].joined(separator: "\t") + "\n"
    }
    for e in sortedEdges(g.edges) {
      out += ["E", e.from, e.to, e.kind.rawValue, "\(e.file):\(e.line)", String(e.more)].joined(separator: "\t") + "\n"
    }
    return out
  }

  public static func decode(_ s: String) throws -> Graph {
    let lines = s.split(separator: "\n", omittingEmptySubsequences: true)
    guard let first = lines.first, first.hasPrefix("# swiftgraph ") else { throw GraphTextError(line: 1) }
    var fields: [String: String] = [:]
    let parts = first.split(separator: " ")
    for p in parts.dropFirst(3) {
      let kv = p.split(separator: "=", maxSplits: 1)
      if kv.count == 2 { fields[String(kv[0])] = String(kv[1]) }
    }
    guard parts.count >= 3, let version = Int(parts[2]), let commit = fields["commit"],
          let stale = Int(fields["stale"] ?? "") else { throw GraphTextError(line: 1) }
    var g = Graph(header: Header(version: version, commit: commit, dirty: fields["dirty"] == "1", staleFiles: stale),
                  nodes: [:], edges: [])
    for (i, raw) in lines.enumerated().dropFirst() {
      let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      let bad = GraphTextError(line: i + 1)
      switch f.first {
      case "N":
        guard f.count == 7 else { throw bad }
        let loc = f[5] == "-" ? nil : splitLoc(f[5])
        if f[5] != "-" && loc == nil { throw bad }
        g.nodes[f[1]] = Node(id: f[1], kind: f[2], module: f[3], name: f[4], file: loc?.0, line: loc?.1,
                             isTest: f[6].contains("t"), isExternal: f[6].contains("x"),
                             isProtocolRequirement: f[6].contains("p"))
      case "E":
        guard f.count == 6, let kind = EdgeKind(rawValue: f[3]), let loc = splitLoc(f[4]), let more = Int(f[5])
        else { throw bad }
        g.edges.append(Edge(from: f[1], to: f[2], kind: kind, file: loc.0, line: loc.1, more: more))
      default:
        throw bad
      }
    }
    return g
  }

  static func sortedEdges(_ edges: [Edge]) -> [Edge] {
    edges.sorted { ($0.from, $0.to, $0.kind) < ($1.from, $1.to, $1.kind) }
  }

  /// Splits "path:line" on the last colon (paths may contain spaces or colons).
  private static func splitLoc(_ s: String) -> (String, Int)? {
    guard let i = s.lastIndex(of: ":"), let line = Int(s[s.index(after: i)...]) else { return nil }
    return (String(s[..<i]), line)
  }
}
