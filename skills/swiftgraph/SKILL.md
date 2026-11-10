---
name: swiftgraph
description: Use before grepping to understand Swift code — "who calls X", "what uses this property", "where is this written", "trace this", "callers", "callees", "what does this function touch", and whenever you are understanding, debugging, or refactoring a symbol in a Swift / Xcode codebase. Answers in one call with a compiler-accurate tree of file:line call sites.
---

# swiftgraph

`swiftgraph` answers "who calls / reads / writes this?" and "what does this call / touch?" from the Swift compiler's own index. One call replaces a chain of grep → open → grep.

## Use it first

Before grepping to learn how a Swift symbol is used, run:

```bash
swiftgraph callers <symbol>     # who calls / reads / writes / references it, transitively
swiftgraph callees <symbol>     # what it calls / reads / writes / references, transitively
swiftgraph find <text>          # not sure of the name? list matching symbols
```

`<symbol>` can be `name`, `Type.name`, `Inner.name` for nested types, `Module.Type.name`, `name(label:)`, or the 12-char id from a previous answer. A symbol whose full name matches exactly wins over partial matches.

Options: `--depth N` (default 3), `--limit N` printed nodes (default 150), `--no-tests`, `--exclude <Module>` (repeatable, treat a module as a leaf), `--refs` (`callees` only: also list types and enum cases referenced; hidden by default), `--repo <path>`.

## Ambiguous names

A short name like `body`, `init`, or `id` usually matches several symbols. swiftgraph never guesses: it prints `ambiguous: N matches` with one line per candidate and exits 2:

```
3f9a1c2b7d40  [instanceProperty]  App.HomeView.body  Sources/App/HomeView.swift:18
```

Re-run with the id (first column) or a more qualified name. At most 30 candidates are listed, then `… N more`. `(protocol requirement)` at the end of a candidate line tells a requirement apart from a protocol-extension default of the same name. `find` uses the same format and cap.

## Reading the output

```
Profile.name  [instanceProperty]  Sources/Core/Profile.swift:1          ← root: kind + definition
├─ read by ViewModel.title  Sources/App/ViewModel.swift:8               ← callers: the call site line
│  └─ read by ViewModel.log()  Sources/App/ViewModel.swift:13
├─ written by ViewModel.rename(_:)  Sources/App/ViewModel.swift:9  (+2 more)
│  └─ called by ViewModelTests.testRename()  Tests/…/ViewModelTests.swift:3  [test]
└─ called by ViewModel.persist()  Sources/App/ViewModel.swift:10  via protocol
… 4 more nodes cut (raise --depth / --limit)
```

- Verbs: `called by` / `read by` / `written by` / `referenced by` (callers); `calls` / `reads` / `writes` / `references` (callees).
- `callers` lines show the **call site** — open that line. `callees` lines show the callee's definition, then `(at :N)` = the line in the caller.
- `(+N more)` — the same caller touches it on N more lines.
- `[test]` — test code. `--no-tests` hides it.
- `[external Module]` — system framework or blocklisted third-party module. A leaf; never expanded.
- `via protocol` / `via override` — dynamic dispatch: the call goes through a protocol requirement or base method. Under a callee, the implementations it can dispatch to are listed with this label.
- `… (see above)` — already expanded earlier in this answer. The call site on that line is still the one to open.
- Exit codes: `0` answer printed, `1` no symbol matches, `2` ambiguous (candidates printed), `3` tool error (message on stderr), `64` bad usage.
- `… N more nodes cut` — limits hit. Raise `--depth` / `--limit`, or query a deeper node directly.

## Freshness

The graph reflects the last indexed build. A first line starting with `!` means it may be out of date:

- `! graph built from a stale index …` or `! graph built from <sha>, HEAD is <sha>` — if you need code changed since then, run `swiftgraph index --build` (builds with indexing, then refreshes `.swiftgraph/graph.local.txt`). Plain `swiftgraph index` re-reads existing indexes without building.
- No graph yet? The first query creates one and says `(no graph found; indexed first)`.

CI owns the committed `.swiftgraph/graph.txt` (`swiftgraph index --build --ci`). Local runs write only `graph.local.txt`, which is gitignored. Config (blocklist, project, schemes, explicit store paths) lives in `.swiftgraph/config.json`.

## What it can't see

Only compiler-recorded links. These won't appear — grep for them:

- `NotificationCenter` posts/observers, selectors, KVO, `#keyPath`
- SwiftUI `@Environment` / `@EnvironmentObject` injection
- reflection, string-based lookups, code not built yet

## Running it

Requires macOS with Xcode. If `swiftgraph` is on `PATH`, use it. Otherwise run the wrapper next to this file, `scripts/swiftgraph` (in this skill's base directory). It builds the tool with Xcode's Swift on first use (about a minute) and then runs it:

```bash
<skill base directory>/scripts/swiftgraph callers <symbol>
```

To put it on `PATH` instead, run `xcrun swift build -c release` in the repo root and link `$(xcrun swift build -c release --show-bin-path)/swiftgraph`.
