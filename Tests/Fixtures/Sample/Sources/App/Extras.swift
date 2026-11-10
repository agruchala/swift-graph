import Observation

struct Tag { var label: String }
func makeTag() -> Tag { Tag(label: "x") }

@Observable final class Counter { var count = 0 }
func bump(_ c: Counter) { c.count += 1 }

protocol Stamped { var stamp: Int { get } }
struct Event { var stamp: Int }
extension Event: Stamped {}
func readStamp(_ s: any Stamped) -> Int { s.stamp }
