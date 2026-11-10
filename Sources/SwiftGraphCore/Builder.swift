import Foundation

public enum BuildError: Error, CustomStringConvertible {
  case noBuildConfig
  public var description: String {
    #"no index store found and nothing to build; add "project" and "schemes" to .swiftgraph/config.json"#
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
    throw BuildError.noBuildConfig
  }
}
