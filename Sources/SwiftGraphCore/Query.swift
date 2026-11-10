import Foundation

public enum Direction: Sendable { case callers, callees }

public struct QueryOptions: Sendable {
  public var depth = 3
  public var limit = 150
  public var hideTests = false
  public var exclude: Set<String> = []
  public init() {}
}

public enum Resolution: Equatable { case found(Node), ambiguous([Node]), none }

public struct Query {
  let graph: Graph
  let incoming: [String: [Edge]]
  let outgoing: [String: [Edge]]

  public init(graph: Graph) {
    self.graph = graph
    incoming = Dictionary(grouping: graph.edges, by: \.to)
    outgoing = Dictionary(grouping: graph.edges, by: \.from)
  }

  // MARK: Lookup

  static func stripParens(_ s: String) -> String {
    s.firstIndex(of: "(").map { String(s[..<$0]) } ?? s
  }

  /// Last `.`-component, keeping any `(labels:)` suffix: `ViewModel.rename(_:)` → `rename(_:)`.
  static func lastComponent(_ name: String) -> String {
    let base = stripParens(name)
    guard let dot = base.lastIndex(of: ".") else { return name }
    return String(name[name.index(after: dot)...])
  }

  /// Exact matches (full name or Module.name, with or without `(labels:)`) win; only when there are none do
  /// partial ones count (last component, or a dotted suffix like `Inner.inBody`). Several matches → ambiguous.
  public func resolve(_ text: String) -> Resolution {
    if let n = graph.nodes[text] { return .found(n) }
    let exact = graph.nodes.values.filter { n in
      let full = n.module + "." + n.name
      return n.name == text || Self.stripParens(n.name) == text || full == text || Self.stripParens(full) == text
    }
    let matches = !exact.isEmpty ? exact : graph.nodes.values.filter { n in
      if n.name.hasSuffix("." + text) || Self.stripParens(n.name).hasSuffix("." + text) { return true }
      guard !text.contains(".") else { return false }
      let last = Self.lastComponent(n.name)
      return last == text || Self.stripParens(last) == text
    }
    switch matches.count {
    case 0: return .none
    case 1: return .found(matches[0])
    default: return .ambiguous(matches.sorted { ($0.name, $0.id) < ($1.name, $1.id) })
    }
  }

  public func find(_ text: String, max: Int = 30) -> [Node] {
    let t = text.lowercased()
    return Array(graph.nodes.values.filter { $0.name.lowercased().contains(t) }
      .sorted { ($0.name, $0.id) < ($1.name, $1.id) }.prefix(max))
  }

  /// Candidate lines, at most `max`, then how many were left out.
  public static func candidates(_ ns: [Node], max: Int = 30) -> String {
    var out = ns.prefix(max).map { candidateLine($0) + "\n" }.joined()
    if ns.count > max { out += "… \(ns.count - max) more; qualify with Type.name, Module.Type.name, or an id\n" }
    return out
  }

  public static func candidateLine(_ n: Node) -> String {
    "\(n.id)  [\(n.kind)]  \(n.module).\(n.name)  \(loc(n) ?? "external")" + (n.isProtocolRequirement ? "  (protocol requirement)" : "")
  }

  static func loc(_ n: Node) -> String? { n.file.map { "\($0):\(n.line ?? 0)" } }

  // MARK: Tree

  struct Child {
    var verb: String?  // nil for implementers listed under a protocol requirement / base method
    var node: Node
    var edge: Edge?  // nil for implementers
    var via: String?
  }

  static func verb(_ k: EdgeKind, _ d: Direction) -> String {
    switch (k, d) {
    case (.call, .callers): "called by"
    case (.read, .callers): "read by"
    case (.write, .callers): "written by"
    case (.call, .callees): "calls"
    case (.read, .callees): "reads"
    case (.write, .callees): "writes"
    case (_, .callers): "referenced by"
    case (_, .callees): "references"
    }
  }

  func via(_ base: Node) -> String { base.isProtocolRequirement ? "via protocol" : "via override" }

  func children(_ n: Node, _ dir: Direction, _ opts: QueryOptions) -> [Child] {
    func keep(_ c: Child) -> Bool { !(opts.hideTests && c.node.isTest) }
    func bySite(_ a: Child, _ b: Child) -> Bool {
      (a.edge?.file ?? a.node.file ?? "", a.edge?.line ?? a.node.line ?? 0, a.node.name)
        < (b.edge?.file ?? b.node.file ?? "", b.edge?.line ?? b.node.line ?? 0, b.node.name)
    }
    var direct: [Child] = []
    var dispatch: [Child] = []
    switch dir {
    case .callers:
      for e in incoming[n.id] ?? [] where e.kind != .override {
        if let from = graph.nodes[e.from] { direct.append(Child(verb: Self.verb(e.kind, dir), node: from, edge: e)) }
      }
      // Calls made through every protocol requirement / base method this node implements, up the chain.
      var bases: [Node] = []
      var seenBases: Set<String> = [n.id]
      var frontier = [n.id]
      while let id = frontier.popLast() {
        for o in outgoing[id] ?? [] where o.kind == .override && seenBases.insert(o.to).inserted {
          if let b = graph.nodes[o.to] { bases.append(b); frontier.append(b.id) }
        }
      }
      for base in bases {
        for e in incoming[base.id] ?? [] where e.kind != .override {
          if let from = graph.nodes[e.from] {
            dispatch.append(Child(verb: Self.verb(e.kind, dir), node: from, edge: e, via: via(base)))
          }
        }
      }
    case .callees:
      for e in outgoing[n.id] ?? [] where e.kind != .override {
        if let to = graph.nodes[e.to] { direct.append(Child(verb: Self.verb(e.kind, dir), node: to, edge: e)) }
      }
      // Implementations a call to this requirement / base method can dispatch to.
      for o in incoming[n.id] ?? [] where o.kind == .override {
        if let impl = graph.nodes[o.from] { dispatch.append(Child(verb: nil, node: impl, edge: nil, via: via(n))) }
      }
    }
    return direct.filter(keep).sorted(by: bySite) + dispatch.filter(keep).sorted(by: bySite)
  }

  func isLeaf(_ n: Node, _ opts: QueryOptions) -> Bool { n.isExternal || opts.exclude.contains(n.module) }

  public func tree(_ root: Node, _ dir: Direction, _ opts: QueryOptions) -> String {
    var out = "\(root.name)  [\(root.kind)]  \(Self.loc(root) ?? "[external \(root.module)]")\n"
    var printed: Set<String> = [root.id]
    var expanded: Set<String> = [root.id]
    var count = 0

    func line(_ c: Child) -> String {
      let head = (c.verb.map { $0 + " " } ?? "") + c.node.name
      if isLeaf(c.node, opts) { return c.node.module == "external" ? "\(head)  [external]" : "\(head)  [external \(c.node.module)]" }
      if expanded.contains(c.node.id) { return "\(head)  … (see above)" }
      var s = head + "  "
      if dir == .callers, let e = c.edge {
        s += "\(e.file):\(e.line)"
      } else {
        s += Self.loc(c.node) ?? "?"
        if let e = c.edge { s += "  (at :\(e.line))" }
      }
      if let more = c.edge?.more, more > 0 { s += "  (+\(more) more)" }
      if c.node.isTest { s += "  [test]" }
      if let v = c.via { s += "  " + v }
      return s
    }

    func walk(_ n: Node, depth: Int, prefix: String) {
      let kids = children(n, dir, opts)
      for (i, c) in kids.enumerated() {
        guard count < opts.limit else { return }
        let last = i == kids.count - 1
        out += prefix + (last ? "└─ " : "├─ ") + line(c) + "\n"
        count += 1
        printed.insert(c.node.id)
        if depth < opts.depth, !isLeaf(c.node, opts), !expanded.contains(c.node.id) {
          expanded.insert(c.node.id)
          walk(c.node, depth: depth + 1, prefix: prefix + (last ? "   " : "│  "))
        }
      }
    }
    walk(root, depth: 1, prefix: "")

    // Everything reachable that never made it onto the page.
    var reachable: Set<String> = [root.id]
    var queue = [root]
    while let n = queue.popLast() {
      guard n.id == root.id || !isLeaf(n, opts) else { continue }
      for c in children(n, dir, opts) where reachable.insert(c.node.id).inserted { queue.append(c.node) }
    }
    let cut = reachable.subtracting(printed).count
    if cut > 0 { out += "… \(cut) more nodes cut (raise --depth / --limit)\n" }
    return out
  }
}
