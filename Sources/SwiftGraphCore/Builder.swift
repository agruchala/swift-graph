import Foundation

public enum BuildError: Error, CustomStringConvertible {
  /// Projects found at the repo root with their shared/user schemes, e.g. `App.xcodeproj: App, Widget`.
  case noBuildConfig(found: [String])
  public var description: String {
    guard case .noBuildConfig(let found) = self else { return "" }
    var s = #"no index store found and nothing to build; add "project" and "schemes" to .swiftgraph/config.json"#
    for f in found { s += "\n  found " + f }
    return s
  }

  public static func noBuildConfig(repo: URL) -> BuildError {
    let fm = FileManager.default
    let projects = ((try? fm.contentsOfDirectory(atPath: repo.path)) ?? [])
      .filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }.sorted()
    return .noBuildConfig(found: projects.map { p in
      // Scheme files: xcshareddata/xcschemes/*.xcscheme, plus per-user ones Xcode autocreates.
      var dirs = [p + "/xcshareddata/xcschemes"]
      for u in (try? fm.contentsOfDirectory(atPath: repo.path + "/" + p + "/xcuserdata")) ?? [] {
        dirs.append(p + "/xcuserdata/" + u + "/xcschemes")
      }
      let schemes = Set(dirs.flatMap { (try? fm.contentsOfDirectory(atPath: repo.path + "/" + $0)) ?? [] }
        .filter { $0.hasSuffix(".xcscheme") }.map { String($0.dropLast(".xcscheme".count)) })
      return "\(p): " + (schemes.isEmpty ? "(no schemes found)" : schemes.sorted().joined(separator: ", "))
    })
  }
}

/// Runs a build with indexing enabled and returns the index store paths it produced.
public enum Builder {
  public static func build(repo: URL, config: Config) throws -> [String] {
    let fm = FileManager.default
    if let project = config.project, !config.schemes.isEmpty {
      let dd = GraphStore.dir(repo).appendingPathComponent("DerivedData").path
      let flag = project.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
      for s in config.schemes {
        try sh(["xcodebuild", "build-for-testing", flag, project, "-scheme", s.name, "-destination", s.destination,
                "-derivedDataPath", dd, "COMPILER_INDEX_STORE_ENABLE=YES", "-quiet"], cwd: repo)
      }
      return [dd + "/Index.noindex/DataStore"]
    }
    if fm.fileExists(atPath: repo.appendingPathComponent("Package.swift").path) {
      try sh(["xcrun", "swift", "build", "--build-tests", "--enable-index-store"], cwd: repo)
      var c = config
      c.stores = []
      return StoreLocator.find(repoRoot: repo, config: c)
    }
    throw BuildError.noBuildConfig(repo: repo)
  }
}
