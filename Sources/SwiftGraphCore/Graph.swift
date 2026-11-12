import CryptoKit
import Foundation

public enum EdgeKind: String, Sendable, Comparable {
  case call, read, write, ref, override
  public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

public struct Node: Hashable, Sendable {
  public var id: String
  public var kind: String
  public var module: String
  public var name: String  // display name: "Container.member(label:)" or "Type"
  public var file: String?
  public var line: Int?
  public var isTest: Bool
  public var isExternal: Bool
  public var isProtocolRequirement: Bool

  public init(id: String, kind: String, module: String, name: String, file: String?, line: Int?,
              isTest: Bool, isExternal: Bool, isProtocolRequirement: Bool) {
    self.id = id; self.kind = kind; self.module = module; self.name = name; self.file = file; self.line = line
    self.isTest = isTest; self.isExternal = isExternal; self.isProtocolRequirement = isProtocolRequirement
  }
}

public struct Edge: Hashable, Sendable {
  public var from: String
  public var to: String
  public var kind: EdgeKind
  public var file: String  // first call site (repo-relative)
  public var line: Int
  public var more: Int  // additional call sites of the same (from, to, kind)

  public init(from: String, to: String, kind: EdgeKind, file: String, line: Int, more: Int) {
    self.from = from; self.to = to; self.kind = kind; self.file = file; self.line = line; self.more = more
  }
}

public struct Header: Equatable, Sendable {
  public var version = 1
  public var commit: String
  public var dirty: Bool
  public var staleFiles: Int

  public init(version: Int = 1, commit: String, dirty: Bool, staleFiles: Int) {
    self.version = version; self.commit = commit; self.dirty = dirty; self.staleFiles = staleFiles
  }
}

public struct Graph: Equatable, Sendable {
  public var header: Header
  public var nodes: [String: Node]
  public var edges: [Edge]
  /// Files an earlier graph had index data for that are still in the repo but have none now (store wiped or
  /// partly rebuilt). Carried into the next plain `index` so the warning survives until a full build.
  public var missing: [String]

  public init(header: Header, nodes: [String: Node], edges: [Edge], missing: [String] = []) {
    self.header = header; self.nodes = nodes; self.edges = edges; self.missing = missing
  }
}

/// Stable short id: first 12 hex chars of SHA-256(usr).
public func nodeID(usr: String) -> String {
  SHA256.hash(data: Data(usr.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
}
