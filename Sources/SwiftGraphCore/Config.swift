import Foundation

/// `.swiftgraph/config.json`. Every field is optional in the file.
public struct Config: Codable, Equatable, Sendable {
  public struct Scheme: Codable, Equatable, Sendable {
    public var name: String
    public var destination: String
    public init(name: String, destination: String) { self.name = name; self.destination = destination }
  }

  public var blocklist: [String] = []
  public var stores: [String] = []  // explicit paths, repo-relative or absolute
  public var project: String? = nil  // e.g. "App.xcodeproj" or "App.xcworkspace"
  public var schemes: [Scheme] = []

  public init() {}

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    blocklist = try c.decodeIfPresent([String].self, forKey: .blocklist) ?? []
    stores = try c.decodeIfPresent([String].self, forKey: .stores) ?? []
    project = try c.decodeIfPresent(String.self, forKey: .project)
    schemes = try c.decodeIfPresent([Scheme].self, forKey: .schemes) ?? []
  }

  public static func load(repoRoot: URL) throws -> Config {
    let url = repoRoot.appendingPathComponent(".swiftgraph/config.json")
    guard let data = FileManager.default.contents(atPath: url.path) else { return Config() }
    return try JSONDecoder().decode(Config.self, from: data)
  }
}
