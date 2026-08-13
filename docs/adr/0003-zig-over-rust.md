# Zig, not Rust

devrun is written in Zig 0.16, with libvaxis for the TUI and zig-yaml for config.

The technical comparison came out close to even, and far closer than expected. All three arguments that initially favoured Rust failed on inspection: libvaxis targets 0.16 and is as actively maintained as ratatui; zig-yaml handles the plain YAML this config actually uses; and the workload is roughly twelve file descriptors, so neither language needs an async runtime. What remained was one genuine edge each — serde derive versus a hand-written tree walk for config mapping, set against 600–900 lines of proven supervisor code in mandor and its author being reachable.

The tiebreaker was not technical. Zig is pre-1.0, and every release is a maintenance event across the whole dependency set — a real, recurring cost, and the strongest remaining argument for Rust in a tool meant to be boring infrastructure. That cost was accepted deliberately. Wanting to work in Zig is a legitimate reason to choose it, and it is recorded here so a future reader does not mistake the choice for a claim that Zig was technically superior. It was not; it was close, and this was the thumb on the scale.

## Considered Options

- **Rust** — better config ergonomics through serde and a quieter decade of maintenance, but no reuse from mandor and a much harder path to a macOS cross-build.
- **Split: Zig supervisor, Rust TUI** — rejected. Two build systems and two languages to buy a difference measured at roughly 1.5 MB of RSS and 1 MB of binary.
- **Binary size and memory as deciding factors** — rejected on measurement. Projected RSS is ~33 MB either way, and ~95% of it is the Window size we chose ourselves. mandor's 359 KB matters because it is PID 1 in a scratch container and the binary *is* the image; devrun is a laptop tool where that number buys nothing.
