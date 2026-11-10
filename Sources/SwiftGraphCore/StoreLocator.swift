import Foundation

public enum StoreLocator {
  public static let defaultDerivedData = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Developer/Xcode/DerivedData")

  /// Index stores for `repoRoot`: `config.stores` if set, else the local `.swiftgraph/DerivedData`,
  /// Xcode DerivedData folders whose workspace lives in the repo, and SwiftPM stores under `.build`.
  public static func find(repoRoot: URL, config: Config, derivedDataRoot: URL = defaultDerivedData) -> [String] {
    let fm = FileManager.default
    let root = repoRoot.standardizedFileURL.path
    if !config.stores.isEmpty {
      return config.stores.map { $0.hasPrefix("/") ? $0 : root + "/" + $0 }
    }
    var found: [String] = []

    let local = root + "/.swiftgraph/DerivedData/Index.noindex/DataStore"
    if fm.fileExists(atPath: local) { found.append(local) }

    for dir in (try? fm.contentsOfDirectory(atPath: derivedDataRoot.path)) ?? [] {
      let base = derivedDataRoot.appendingPathComponent(dir)
      let store = base.appendingPathComponent("Index.noindex/DataStore").path
      guard fm.fileExists(atPath: store),
            let data = fm.contents(atPath: base.appendingPathComponent("info.plist").path),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let ws = plist["WorkspacePath"] as? String,
            ws == root || ws.hasPrefix(root + "/")
      else { continue }
      found.append(store)
    }

    var buildDirs = [root + "/.build"]
    for sub in (try? fm.contentsOfDirectory(atPath: root)) ?? [] { buildDirs.append(root + "/" + sub + "/.build") }
    for b in buildDirs where fm.fileExists(atPath: b) { found += swiftPMStores(in: b, depth: 5) }

    return found.sorted()
  }

  /// Directories holding `v5/units` (SwiftPM `index/store`, Swift Build `.build/out`).
  static func swiftPMStores(in dir: String, depth: Int) -> [String] {
    let fm = FileManager.default
    if fm.fileExists(atPath: dir + "/v5/units") { return [dir] }
    guard depth > 0 else { return [] }
    let skip: Set<String> = ["checkouts", "repositories", "artifacts"]
    var out: [String] = []
    for sub in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where !skip.contains(sub) && !sub.hasSuffix(".noindex") {
      var isDir: ObjCBool = false
      let p = dir + "/" + sub
      if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { out += swiftPMStores(in: p, depth: depth - 1) }
    }
    return out
  }
}
