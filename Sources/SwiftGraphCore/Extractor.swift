import Foundation
import IndexStoreDB

public func isTestModule(_ module: String) -> Bool { module.hasSuffix("Tests") }

/// Reads index stores and builds the call/access graph for source files tracked in `repoRoot`.
public struct Extractor {
  public var repoRoot: URL
  public var storePaths: [String]
  public var blocklist: Set<String>
  public var libIndexStorePath: String?

  public init(repoRoot: URL, storePaths: [String], blocklist: Set<String>, libIndexStorePath: String? = nil) {
    self.repoRoot = repoRoot.standardizedFileURL
    self.storePaths = storePaths
    self.blocklist = blocklist
    self.libIndexStorePath = libIndexStorePath
  }

  public static func defaultLibPath() throws -> String {
    let dev = try sh(["xcode-select", "-p"], cwd: URL(fileURLWithPath: "/"))
    return dev + "/Toolchains/XcodeDefault.xctoolchain/usr/lib/libIndexStore.dylib"
  }

  static let keptKinds: Set<IndexSymbolKind> = [
    .class, .struct, .enum, .protocol, .function, .instanceMethod, .classMethod, .staticMethod,
    .instanceProperty, .classProperty, .staticProperty, .constructor, .destructor, .enumConstant, .variable,
  ]
  static let typeKinds: Set<IndexSymbolKind> = [.class, .struct, .enum, .protocol]

  /// Swift accessor names look like `getter:name`, `setter:subscript(_:)`, `didSet:x`.
  static func isAccessorName(_ name: String) -> Bool {
    guard let colon = name.firstIndex(of: ":") else { return false }
    return name.firstIndex(of: "(").map { colon < $0 } ?? true
  }

  /// Module encoded in a Swift USR (`s:10Foundation4DateV` → Foundation), else "external".
  static func moduleFromUSR(_ usr: String) -> String {
    guard usr.hasPrefix("s:") else { return "external" }
    let rest = usr.dropFirst(2)
    if rest.hasPrefix("S"), let c = rest.dropFirst().first, c != "o", c != "C" { return "Swift" }  // stdlib substitutions
    let digits = rest.prefix { $0.isNumber }
    guard let len = Int(digits), rest.count >= digits.count + len else { return "external" }
    return String(rest.dropFirst(digits.count).prefix(len))
  }

  /// Repo-relative Swift sources: git's tracked + untracked-not-ignored files, or a directory walk when
  /// `repoRoot` isn't a git repo. `.swiftgraph/` (its DerivedData holds generated code) is never included.
  static func swiftFiles(repoRoot: URL) -> [String] {
    var files: [String]
    if let out = try? sh(["git", "-c", "core.quotePath=false", "ls-files", "-z", "--cached", "--others",
                          "--exclude-standard", "--", "*.swift"], cwd: repoRoot) {
      files = out.split(separator: "\0").map(String.init)
    } else {
      files = []
      let base = repoRoot.standardizedFileURL.path + "/"
      let e = FileManager.default.enumerator(at: repoRoot, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants])
      while let u = e?.nextObject() as? URL {
        if u.pathExtension == "noindex" || u.lastPathComponent == "DerivedData" { e?.skipDescendants(); continue }
        let path = u.standardizedFileURL.path
        if u.pathExtension == "swift", path.hasPrefix(base) { files.append(String(path.dropFirst(base.count))) }
      }
    }
    return files.filter { !$0.hasPrefix(".swiftgraph/") }.sorted()
  }

  public func extract() throws -> Graph {
    let root = repoRoot.path
    let files = Self.swiftFiles(repoRoot: repoRoot)

    var dbs: [IndexStoreDB] = []
    var tempDirs: [URL] = []
    defer { for d in tempDirs { try? FileManager.default.removeItem(at: d) } }
    let uniqueStores = Array(Set(storePaths)).sorted()
    if !uniqueStores.isEmpty {
      let lib = try IndexStoreLibrary(dylibPath: libIndexStorePath ?? Self.defaultLibPath())
      for store in uniqueStores {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("swiftgraph-\(UUID().uuidString)")
        tempDirs.append(tmp)
        let db = try IndexStoreDB(storePath: store, databasePath: tmp.path, library: lib,
                                  waitUntilDoneInitializing: true, listenToUnitEvents: false)
        db.pollForUnitChangesAndWait()
        dbs.append(db)
      }
    }

    // Per file: occurrences from the store with the newest unit for it.
    var perFile: [(rel: String, occs: [SymbolOccurrence])] = []
    var stale = 0
    var unindexed: [Date] = []  // mtimes of files no store has a unit for
    for rel in files {
      let abs = root + "/" + rel
      var best: (IndexStoreDB, Date)?
      for db in dbs {
        if let d = db.dateOfLatestUnitFor(filePath: abs), best.map({ d > $0.1 }) ?? true { best = (db, d) }
      }
      let mtime = (try? FileManager.default.attributesOfItem(atPath: abs))?[.modificationDate] as? Date
      guard let (db, date) = best else {
        if let mtime { unindexed.append(mtime) }
        continue
      }
      if let mtime, mtime > date { stale += 1 }
      perFile.append((rel, db.symbolOccurrences(inFilePath: abs)))
    }
    // A file with no unit that is newer than the newest build is new since then (Package.swift and other
    // never-compiled files are older, so they don't count).
    if let newest = perFile.compactMap({ f in dbs.compactMap { $0.dateOfLatestUnitFor(filePath: root + "/" + f.rel) }.max() }).max() {
      stale += unindexed.filter { $0 > newest }.count
    }

    // Pass 1: definitions.
    var defs: [String: (sym: Symbol, occ: SymbolOccurrence, rel: String)] = [:]
    var nameOf: [String: String] = [:]
    var parentOf: [String: Symbol] = [:]
    var accessorOf: [String: String] = [:]  // accessor USR → property USR
    var implicit: Set<String> = []  // synthesized (memberwise inits, NSObject overrides): kept only if linked
    // (impl USR, base USR, site). Recorded on definitions, and as implicit occurrences at
    // retroactive conformances (`extension Foo: Proto {}`).
    var overrides: [(String, String, String, SymbolLocation)] = []
    var extendedType: [String: String] = [:]  // extension USR → extended type USR
    for (rel, occs) in perFile {
      for o in occs {
        for r in o.relations where r.roles.contains(.overrideOf) { overrides.append((o.symbol.usr, r.symbol.usr, rel, o.location)) }
        for r in o.relations where r.roles.contains(.extendedBy) { extendedType[r.symbol.usr] = o.symbol.usr }
      }
      for o in occs where o.roles.contains(.definition) {
        let usr = o.symbol.usr
        if let prop = o.relations.first(where: { $0.roles.contains(.accessorOf) }) {
          accessorOf[usr] = prop.symbol.usr
          continue
        }
        if nameOf[usr] == nil { nameOf[usr] = o.symbol.name }
        if let p = o.relations.first(where: { $0.roles.contains(.childOf) }), parentOf[usr] == nil { parentOf[usr] = p.symbol }
        guard Self.keptKinds.contains(o.symbol.kind), !o.symbol.properties.contains(.local), defs[usr] == nil
        else { continue }
        defs[usr] = (o.symbol, o, rel)
        if o.roles.contains(.implicit) { implicit.insert(usr) }
      }
    }

    func displayName(_ usr: String, depth: Int = 0) -> String {
      // Members of `extension Outer.Inner` are named through the extended type, like members declared in its body.
      if depth < 8, let t = extendedType[usr], nameOf[t] != nil { return displayName(t, depth: depth + 1) }
      let own = nameOf[usr] ?? usr
      guard depth < 8, let p = parentOf[usr] else { return own }
      return displayName(p.usr, depth: depth + 1) + "." + own
    }

    var nodes: [String: Node] = [:]
    var idOf: [String: String] = [:]
    for (usr, d) in defs {
      let id = nodeID(usr: usr)
      idOf[usr] = id
      let module = d.occ.location.moduleName
      nodes[id] = Node(id: id, kind: "\(d.sym.kind)", module: module, name: displayName(usr),
                       file: d.rel, line: d.occ.location.line, isTest: isTestModule(module),
                       isExternal: blocklist.contains(module),
                       isProtocolRequirement: parentOf[usr]?.kind == .protocol)
    }

    // Pass 2: references → edges. Sites keyed by (from, to, kind), deduped by exact position.
    struct Key: Hashable { var from: String, to: String, kind: EdgeKind }
    struct Site: Hashable, Comparable {
      var file: String, line: Int, col: Int
      static func < (a: Site, b: Site) -> Bool { (a.file, a.line, a.col) < (b.file, b.line, b.col) }
    }
    var sites: [Key: Set<Site>] = [:]

    for (rel, occs) in perFile {
      // Type references by position, to qualify external constructors (`Date()` → `Date.init()`).
      var typeAt: [Int: [Int: String]] = [:]
      for o in occs where Self.typeKinds.contains(o.symbol.kind) && o.roles.contains(.reference) {
        typeAt[o.location.line, default: [:]][o.location.utf8Column] = o.symbol.name
      }
      // Implicit references (result builders, literals, property wrappers, macro expansions) aren't code anyone wrote.
      for o in occs where o.roles.contains(.reference) && !o.roles.contains(.implicit) {
        if blocklist.contains(o.location.moduleName) { break }
        let sym = o.symbol
        guard Self.keptKinds.contains(sym.kind), !sym.properties.contains(.local), !Self.isAccessorName(sym.name)
        else { continue }  // accessor calls are duplicated by the property's own read/write occurrence
        guard let callerUSR = o.relations.lazy
          .filter({ $0.roles.contains(.calledBy) || $0.roles.contains(.containedBy) })
          .map({ accessorOf[$0.symbol.usr] ?? $0.symbol.usr })
          .first(where: { defs[$0] != nil }),
          let from = idOf[callerUSR]
        else { continue }

        let kind: EdgeKind =
          o.roles.contains(.call) ? .call : o.roles.contains(.write) ? .write : o.roles.contains(.read) ? .read : .ref
        let to: String
        if let id = idOf[sym.usr] {
          to = id
        } else {
          if kind == .ref { continue }
          to = nodeID(usr: sym.usr)
          if nodes[to] == nil {
            let container = o.relations.first(where: { $0.roles.contains(.receivedBy) })?.symbol.name
              ?? (sym.kind == .constructor ? typeAt[o.location.line]?[o.location.utf8Column] : nil)
            nodes[to] = Node(id: to, kind: "\(sym.kind)", module: Self.moduleFromUSR(sym.usr),
                             name: container.map { "\($0).\(sym.name)" } ?? sym.name,
                             file: nil, line: nil, isTest: false, isExternal: true, isProtocolRequirement: false)
          }
        }
        sites[Key(from: from, to: to, kind: kind), default: []]
          .insert(Site(file: rel, line: o.location.line, col: o.location.utf8Column))
      }
    }

    // Override / conformance edges between our own definitions (accessor-level ones lifted to the property).
    for (implUSR, baseUSR, rel, loc) in overrides {
      guard let impl = idOf[accessorOf[implUSR] ?? implUSR], let base = idOf[accessorOf[baseUSR] ?? baseUSR], impl != base,
            nodes[impl]?.isExternal == false, nodes[base]?.isExternal == false else { continue }
      sites[Key(from: impl, to: base, kind: .override), default: []]
        .insert(Site(file: rel, line: loc.line, col: loc.utf8Column))
    }

    var edges: [Edge] = []
    for (k, s) in sites {
      let first = s.min()!
      // Several columns on one line count once: `(+N more)` is about lines to open.
      let lines = Set(s.map { "\($0.file):\($0.line)" }).count
      edges.append(Edge(from: k.from, to: k.to, kind: k.kind, file: first.file, line: first.line, more: lines - 1))
    }

    // Blocklisted symbols stay only as edge targets; synthesized ones only when linked.
    let targets = Set(edges.map(\.to))
    let linked = targets.union(edges.map(\.from))
    let implicitIDs = Set(implicit.compactMap { idOf[$0] })
    nodes = nodes.filter {
      $0.value.isExternal ? targets.contains($0.key) : (!implicitIDs.contains($0.key) || linked.contains($0.key))
    }

    let commit = (try? sh(["git", "rev-parse", "HEAD"], cwd: repoRoot)) ?? "none"
    let dirty = !((try? sh(["git", "status", "--porcelain", "--", "*.swift"], cwd: repoRoot)) ?? "").isEmpty
    return Graph(header: Header(commit: commit.isEmpty ? "none" : commit, dirty: dirty, staleFiles: stale),
                 nodes: nodes, edges: GraphText.sortedEdges(edges))
  }
}
