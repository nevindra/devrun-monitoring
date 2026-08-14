# Render log bytes straight through, rather than through a cell grid

The TUI is written directly against terminal escape sequences. libvaxis, named in [0003](0003-zig-over-rust.md) as the TUI library, is not used.

That ADR chose libvaxis before the log pane had a concrete requirement. It has one now, and it is the one thing devrun exists to do: an Archive is kept **byte-faithful with its ANSI intact**, and the pane's whole job is to put those bytes on a screen.

A cell-grid library cannot pass bytes through. It owns a `Cell` per screen position, each carrying a typed style, and it computes the frame by diffing that grid. To display a line a Worker coloured, every SGR sequence in it has to be parsed into libvaxis's `Style`, written into cells, and re-encoded on the way out. That is a per-frame cost to arrive back at bytes we already had, and it is lossy in exactly the places that matter — a `\e[38;2;…m` truecolour run, an OSC 8 hyperlink from a test runner, a sequence the parser does not model. Writing the bytes through costs nothing and cannot be wrong.

So the pane is one buffer, built whole and written with one `write(2)`. Log bytes are `memcpy`'d into it verbatim. The only thing devrun computes about them is *width* — how many visible columns a line occupies, so it can be truncated at a column boundary instead of inside a colour code, which is `fitToWidth` in `src/term.zig` and about forty lines.

Two smaller consequences pushed the same way. libvaxis's `Loop` runs a reader thread and installs its own `SIGWINCH` handler, both of which fight the single-threaded `poll()` loop and self-pipe that [0004](0004-portability-posture.md) requires; driving vaxis manually to avoid that discards most of what it was providing. And devrun now has no fetched dependencies at all — only vendored zig-yaml — which removes the recurring per-release maintenance that 0003 identified as the strongest argument against Zig in the first place.

## Consequences

- Truecolour, hyperlinks, and any other sequence a Worker emits reach the terminal unmodified, because nothing on the path interprets them.
- devrun owns its terminal handling: raw mode, the alternate screen, key decoding, and resize. That is `src/term.zig`, and it is small because a log viewer needs no widgets — no layout engine, no focus model, no mouse.
- Width measurement is ours to get right. `charWidth` covers the CJK and emoji ranges and treats combining marks as zero; it is not a full Unicode width table, and a rare codepoint may be off by one column. The failure is a line that truncates a column early, which is why this was an acceptable trade against parsing every escape a Worker writes.
- Nothing here is Linux-specific beyond three `ioctl` numbers, so the macOS posture in 0004 is unchanged.
