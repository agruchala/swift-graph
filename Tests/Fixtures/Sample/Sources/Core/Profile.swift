public struct Profile { public var name: String; public init(name: String) { self.name = name } }
public protocol Store { func save(_ p: Profile) }
public final class DiskStore: Store { public init() {}; public func save(_ p: Profile) { helper() }; func helper() {} }
