import Foundation
import Core
import Vendor
public final class ViewModel {
  var profile = Profile(name: "a")
  let store: Store = DiskStore()
  public init() {}
  public var title: String { profile.name }
  public func rename(_ n: String) { profile.name = n }
  public func persist() { store.save(profile) }
  public func stamp() -> Date { Date() }
  public func later() { DispatchQueue.main.async { self.persist() } }
  public func log() { Vendor.track(title) }
  public func loop(_ n: Int) { if n > 0 { loop(n - 1) } }
}
