# Logs travel through the filesystem, not through the control socket

Every Worker's output is written to its Archive on disk from the moment it spawns, and everything that reads logs — the TUI, `devrun logs`, `tail -f`, a pager — reads from there. The control socket carries commands and state only: start, stop, restart, status, Samples.

process-compose solves this with a WebSocket endpoint that streams log lines to clients, which needs framing, per-client subscriptions, and backpressure handling for clients that fall behind. We were already writing logs to disk to make copy and export work, so that machinery would have been a second transport for data already durable somewhere better. Dropping it removes the largest subsystem in the project before it is written.

## Consequences

- Scrolling past the in-memory Window is a `pread` into the page cache — RAM speed for anything written this Session, and it does not count against our RSS the way a larger Window would.
- The socket never moves bulk data, so it stays a trivial line protocol over a unix socket rather than HTTP. No port to allocate, and no accidental network exposure.
- Attaching a TUI from another machine is not possible. Nobody wanted it, and an Archive is a file — files have `scp`.
