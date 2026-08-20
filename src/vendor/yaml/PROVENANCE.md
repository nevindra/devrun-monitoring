# Vendored: zig-yaml

Source: https://github.com/kubkon/zig-yaml
Commit: `84d747bc80937a08ea1cf76a63fee12c5fb1dd61` (version 0.3.0, 2026-01-13)
License: MIT — see `LICENSE`, copyright (c) 2021 Jakub Konka

Only `src/` is vendored. Two local patches, marked in the source — see below.

## Local patches

**`Parser.zig`, flow-sequence comment check.** Upstream rejects any comment
following a flow sequence, including one on the next line:

```yaml
env_file: [".env"]
# perfectly valid YAML — upstream errors here
run: "..."
```

The guard is meant to catch `[a, b]# c`, where the comment touches the closing
bracket, but `eatToken` runs `eatCommentsAndSpace` first and that skips
`.new_line`, so the adjacency test never actually tests adjacency. The patch
compares the comment's line against the closing bracket's line and puts the
token back when they differ. Grep for `devrun patch` to find it.

This is not cosmetic: real configs have exactly this shape, so devrun could not
read them without it.

Not yet reported upstream.

**`Parser.zig`, reading one token past the end.** A document that stops on a
bare key leaves the token iterator past the last token, and `Parser.map` calls
`getCol` with that index before the `next()` that would have caught it. The
array is indexed with no bounds check, so this:

```yaml
services:
```

took devrun down with `index out of bounds: index 4, len 4` rather than telling
its author the file was incomplete. The patch checks `peek()` first and returns
the `UnexpectedEof` the following line already returns. Grep for `devrun patch`.

Not yet reported upstream.

## Known limitation, not patched

**Flow mappings are read as nothing.** `{a: b}` resolves to an empty value
instead of a map, and only fails outright with more than one pair:

| written | parsed as |
| --- | --- |
| `after: {db: ready}` | empty |
| `after: {db: ready, api: ok}` | parse error |
| `env_file: [".env", ".env.local"]` | list, correctly |

Flow *sequences* are fine; it is mappings that are broken. Fixing it means real
work in `Parser.zig`, so devrun instead refuses an empty value everywhere a
mapping is expected and says why — see `expectMap` and `mapAfter` in
`src/config.zig`, and `docs/adr/0008-devrun-yml.md`. `zig build test` covers
both messages.

Anchors and aliases (`&name`, `*name`) are a second gap: `Tokenizer.zig` emits
the tokens and nothing downstream reads them. `defaults:` exists partly so that
the thing people reach for anchors to do has a way to be said.

## Why vendored rather than fetched

zig-yaml's own `build.zig` does not compile under Zig 0.16. Its line 2 imports
`test/spec.zig` at the top level and line 61 calls into it from a branch guarded
by a *runtime* option, so both branches are always analysed — and `test/spec.zig`
still uses `std.StringArrayHashMap`, which 0.16 removed. Depending on the package
therefore fails at build-graph time no matter what options we pass.

The library sources themselves are clean on 0.16 (`zig build-obj src/lib.zig`
succeeds), so vendoring `src/` skips a broken build script without forking or
patching anything.

## Re-syncing

Copy upstream `src/` over this directory, then **re-apply every patch listed
above** — a straight replacement silently reverts them, and the symptom (devrun
refusing a config it read yesterday) will not point back here. `zig build test`
covers each patch, so run it immediately after re-syncing.

If upstream fixes its `build.zig` *and* lands these patches, go back to a normal
`zig fetch --save` dependency and delete this directory.
