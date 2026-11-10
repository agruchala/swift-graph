import ArgumentParser
import Foundation
import SwiftGraphCore

struct RepoOption: ParsableArguments {
  @Option(help: "Repository root (default: nearest folder with .git or .swiftgraph).")
  var repo: String?

  var url: URL {
    if let repo { return URL(fileURLWithPath: repo).standardizedFileURL }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return GraphStore.findRepoRoot(from: cwd) ?? cwd
  }
}

/// Extracts and writes a graph; returns it with the path written.
func runIndex(repo: URL, build: Bool, ci: Bool) throws -> (Graph, URL) {
  let config = try Config.load(repoRoot: repo)
  var stores = build ? try Builder.build(repo: repo, config: config) : StoreLocator.find(repoRoot: repo, config: config)
  if stores.isEmpty && !build { stores = try Builder.build(repo: repo, config: config) }
  if stores.isEmpty { throw BuildError.noBuildConfig }
  let g = try Extractor(repoRoot: repo, storePaths: stores, blocklist: Set(config.blocklist)).extract()
  return (g, try GraphStore.write(g, repo: repo, ci: ci))
}

func loadOrBootstrap(_ repo: URL) throws -> Graph {
  if let g = try GraphStore.load(repo: repo) { return g }
  let (g, _) = try runIndex(repo: repo, build: false, ci: false)
  print("(no graph found; indexed first)")
  return g
}

/// Resolves `text` or prints why not and exits (2 ambiguous, 1 unknown).
func resolveOrExit(_ q: Query, _ text: String) throws -> Node {
  switch q.resolve(text) {
  case .found(let n): return n
  case .ambiguous(let ns):
    print("ambiguous: \(ns.count) matches")
    ns.forEach { print(Query.candidateLine($0)) }
    throw ExitCode(2)
  case .none:
    print("no symbol matches \"\(text)\"; try: swiftgraph find \(text)")
    throw ExitCode(1)
  }
}

struct Swiftgraph: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "swiftgraph",
    abstract: "Compiler-accurate call/access graph for Swift code.",
    subcommands: [Index.self, Callers.self, Callees.self, Find.self])
}

struct Index: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Build .swiftgraph/graph.local.txt (or graph.txt with --ci) from index stores.")
  @OptionGroup var repo: RepoOption
  @Flag(help: "Run the build from config.json first instead of reading existing index stores.") var build = false
  @Flag(help: "Write the committed graph.txt (for CI).") var ci = false

  func run() throws {
    let (g, url) = try runIndex(repo: repo.url, build: build, ci: ci)
    print("wrote \(url.path): \(g.nodes.count) symbols, \(g.edges.count) edges")
    if let w = GraphStore.warning(for: g, repo: repo.url) { print(w) }
  }
}

struct TreeOptions: ParsableArguments {
  @Argument(help: "Symbol: name, Type.name, Module.Type.name, name(label:), or an id.") var symbol: String
  @Option(help: "Max tree depth.") var depth = 3
  @Option(help: "Max printed nodes.") var limit = 150
  @Flag(name: .customLong("no-tests"), help: "Hide test code.") var noTests = false
  @Option(help: "Treat this module as a leaf (repeatable).") var exclude: [String] = []

  func run(_ dir: Direction, repo: URL) throws {
    let g = try loadOrBootstrap(repo)
    if let w = GraphStore.warning(for: g, repo: repo) { print(w) }
    let q = Query(graph: g)
    let root = try resolveOrExit(q, symbol)
    var o = QueryOptions()
    o.depth = depth
    o.limit = limit
    o.hideTests = noTests
    o.exclude = Set(exclude)
    print(q.tree(root, dir, o), terminator: "")
  }
}

struct Callers: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Who calls / reads / writes / references a symbol, transitively.")
  @OptionGroup var repo: RepoOption
  @OptionGroup var opts: TreeOptions
  func run() throws { try opts.run(.callers, repo: repo.url) }
}

struct Callees: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "What a symbol calls / reads / writes / references, transitively.")
  @OptionGroup var repo: RepoOption
  @OptionGroup var opts: TreeOptions
  func run() throws { try opts.run(.callees, repo: repo.url) }
}

struct Find: ParsableCommand {
  static let configuration = CommandConfiguration(abstract: "List symbols whose name contains the text.")
  @OptionGroup var repo: RepoOption
  @Argument var text: String
  func run() throws {
    let found = Query(graph: try loadOrBootstrap(repo.url)).find(text)
    guard !found.isEmpty else {
      print("no symbol matches \"\(text)\"; try a shorter name")
      throw ExitCode(1)
    }
    found.forEach { print(Query.candidateLine($0)) }
  }
}

Swiftgraph.main()
