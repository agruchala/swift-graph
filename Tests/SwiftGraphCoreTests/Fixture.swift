import Foundation
@testable import SwiftGraphCore

enum Fixture {
  static let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/Sample")

  nonisolated(unsafe) private static var built: Result<String, Error>?
  private static let lock = NSLock()

  /// Builds the fixture (with tests) once per process; returns its index store path.
  static func storePath() throws -> String {
    lock.lock(); defer { lock.unlock() }
    if built == nil {
      built = Result {
        try sh(["xcrun", "swift", "build", "--build-tests", "--enable-index-store", "--package-path", root.path], cwd: root)
        let store = root.appendingPathComponent(".build/out").path
        guard FileManager.default.fileExists(atPath: store + "/v5/units") else {
          throw ShellError(status: 1, stderr: "no index store at \(store)")
        }
        return store
      }
    }
    return try built!.get()
  }
}
