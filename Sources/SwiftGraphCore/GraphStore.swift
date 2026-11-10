import Foundation

/// The `.swiftgraph/` folder: `graph.txt` (committed, CI-owned) and `graph.local.txt` (local, gitignored).
public enum GraphStore {
  public static func dir(_ repo: URL) -> URL { repo.appendingPathComponent(".swiftgraph") }
  static func committed(_ repo: URL) -> URL { dir(repo).appendingPathComponent("graph.txt") }
  static func local(_ repo: URL) -> URL { dir(repo).appendingPathComponent("graph.local.txt") }

  /// Writes `graph.txt` when `ci`, else `graph.local.txt`. Returns the written path.
  @discardableResult
  public static func write(_ g: Graph, repo: URL, ci: Bool) throws -> URL {
    let d = dir(repo)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    let ignore = d.appendingPathComponent(".gitignore")
    if !FileManager.default.fileExists(atPath: ignore.path) {
      try "graph.local.txt\nDerivedData/\n".write(to: ignore, atomically: true, encoding: .utf8)
    }
    let url = ci ? committed(repo) : local(repo)
    try GraphText.encode(g).write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// `graph.local.txt` if it exists and is newer than `graph.txt`, else `graph.txt`, else nil.
  public static func load(repo: URL) throws -> Graph? {
    // ponytail: parses graph.txt on every query; add a SQLite cache if load > 1s
    func mtime(_ u: URL) -> Date? {
      (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date
    }
    let l = local(repo), c = committed(repo)
    let pick: URL?
    switch (mtime(l), mtime(c)) {
    case let (lt?, ct?): pick = lt > ct ? l : c
    case (_?, nil): pick = l
    case (nil, _?): pick = c
    case (nil, nil): pick = nil
    }
    guard let url = pick else { return nil }
    return try GraphText.decode(String(contentsOf: url, encoding: .utf8))
  }

  public static func warning(for g: Graph, repo: URL) -> String? {
    if g.header.staleFiles > 0 {
      return "! graph built from a stale index (\(g.header.staleFiles) files changed since last build); run: swiftgraph index --build"
    }
    guard g.header.commit != "none", let head = try? sh(["git", "rev-parse", "HEAD"], cwd: repo),
          !head.isEmpty, head != g.header.commit else { return nil }
    // Commits since the graph that touch no Swift file (e.g. the one committing graph.txt) don't make it stale.
    // An unknown commit (shallow clone, rewritten history) makes `git diff` fail: warn.
    if (try? sh(["git", "diff", "--quiet", g.header.commit, "HEAD", "--", "*.swift"], cwd: repo)) != nil { return nil }
    return "! graph built from \(g.header.commit.prefix(7)), HEAD is \(head.prefix(7))"
  }

  /// Nearest ancestor (or self) containing `.git` or `.swiftgraph`.
  public static func findRepoRoot(from start: URL) -> URL? {
    var u = start.standardizedFileURL
    while true {
      for marker in [".git", ".swiftgraph"] where FileManager.default.fileExists(atPath: u.appendingPathComponent(marker).path) {
        return u
      }
      let parent = u.deletingLastPathComponent()
      if parent.path == u.path { return nil }
      u = parent
    }
  }
}
