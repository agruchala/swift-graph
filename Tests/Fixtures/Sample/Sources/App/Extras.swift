import Observation

struct Tag { var label: String }
func makeTag() -> Tag { Tag(label: "x") }

@Observable final class Counter { var count = 0 }
func bump(_ c: Counter) { c.count += 1 }

protocol Stamped { var stamp: Int { get } }
struct Event { var stamp: Int }
extension Event: Stamped {}
func readStamp(_ s: any Stamped) -> Int { s.stamp }

func cleanup() {}
final class Holder { deinit { cleanup() } }

enum Outer { struct Inner { func inBody() {} } }
extension Outer.Inner { func inExt() {} }

import Foundation
func objcLengths() -> Int { NSString(string: "a").length + NSMutableString(string: "b").length }

class BaseVM { init() {} }
final class SubVM: BaseVM {}
