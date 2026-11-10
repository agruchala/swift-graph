import Foundation

public struct ShellError: Error, CustomStringConvertible {
  public var status: Int32
  public var stderr: String
  public var description: String { "exit \(status): \(stderr)" }
}

/// Runs `/usr/bin/env args…` in `cwd`; returns trimmed stdout, throws on non-zero exit.
@discardableResult
public func sh(_ args: [String], cwd: URL) throws -> String {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  p.arguments = args
  p.currentDirectoryURL = cwd
  let out = Pipe(), err = Pipe()
  p.standardOutput = out
  p.standardError = err
  try p.run()
  // stderr drained on another thread so neither pipe can fill up and deadlock the child.
  nonisolated(unsafe) var errData = Data()
  let done = DispatchSemaphore(value: 0)
  DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); done.signal() }
  let outData = out.fileHandleForReading.readDataToEndOfFile()
  p.waitUntilExit()
  done.wait()
  let stdout = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  guard p.terminationStatus == 0 else {
    throw ShellError(status: p.terminationStatus, stderr: String(decoding: errData, as: UTF8.self))
  }
  return stdout
}
