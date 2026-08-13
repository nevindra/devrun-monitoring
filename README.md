# devrun

A process runner for local development whose logs you can actually get out of it.

> **Status: early.** The config layer is done and tested; nothing spawns yet.
> See [Roadmap](#roadmap) for exactly what works today. Linux only, Zig 0.16.

## Why

[process-compose](https://github.com/F1bonacc1/process-compose) runs a repo's dev
services well, and this project starts from its config file rather than replacing
it. But getting a log *out* of it is a fight every time — pasting an error into a
chat, saving a stack trace, finding something from twenty minutes ago. The logs
live inside a TUI widget, and once they are in there they stop being data.

devrun inverts that. **Every process writes to a plain file on disk from the
moment it spawns**, and the TUI is a view over those files rather than their
owner. So `tail -f`, `grep`, `less`, `scp`, and your editor all work on day one,
and "copy this log" stops being a feature that has to be invented.

```
                  ┌─ .devrun/logs/<name>.log ──→ tail · grep · less · $EDITOR
process ──stdout──┤
                  └─ in-memory window (8 MB)  ──→ TUI, scrolls past it via pread

.devrun/control.sock ──→ start · stop · restart · status · samples   (never logs)
```

Because logs never cross the socket, the socket stays a trivial line protocol —
no WebSocket framing, no per-client subscriptions, no backpressure handling. And
because the in-memory window is a bounded cache rather than the record, scrolling
past it reads from the page cache: RAM speed, without counting toward RSS.

## Coexistence

devrun reads your existing `process-compose.yaml`. No second config file, nothing
to keep in sync:

```console
$ process-compose up     # your teammate
$ devrun up              # you
```

It supports a strict subset of the schema and **refuses any field it does not
understand** rather than ignoring it. That refusal is deliberate: a silently
skipped field is how two people run the same file and get different behaviour
with nothing on screen to say why.

```console
$ devrun config
devrun: processes.go: unsupported field "log_location". devrun reads a subset of
process-compose's schema and refuses fields it would otherwise ignore, so that
both tools read this file the same way.
```

### Supported subset

| | |
|---|---|
| Top level | `version` (ignored), `shell.shell_command`, `shell.shell_argument` |
| Process | `command`, `description`, `working_dir`, `dotenv`, `environment` |
| Dependencies | `depends_on.<name>.condition` — all five conditions |
| Restart | `availability.restart` — `no`, `always`, `on_failure`, `exit_on_failure` |
| Probes | `readiness_probe.exec.command`, `readiness_probe.http_get.{host,scheme,path,port}` |
| Probe timing | `initial_delay_seconds`, `period_seconds`, `timeout_seconds`, `success_threshold`, `failure_threshold` |

`${VAR}` and `$VAR` expand over the raw file *before* YAML parsing, with `.env`
values taking precedence over the OS environment and unset names becoming empty
— matching process-compose exactly. Shell parameter expansion (`${VAR:-default}`)
is rejected, as it is there.

Omitted fields take process-compose's defaults, not zero: probes default to
`period_seconds: 10`, `timeout_seconds: 1`, `failure_threshold: 3`, and
`http_get` defaults to `127.0.0.1`, `http`, `/`.

## Try it

Requires [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0).

```console
$ zig build
$ zig build test
$ ./zig-out/bin/devrun config path/to/process-compose.yaml
```

`devrun config` parses a file and prints what devrun understood from it — useful
on its own for checking that a config says what you think it says.

## Roadmap

| | | |
|---|---|---|
| 1 | Config — parse, expand, validate | **done** |
| 2 | Spawn, process groups, shutdown ladder | next |
| 3 | Log archive on disk + bounded memory window | |
| 4 | State machine, dependency graph, readiness probes | |
| 5 | Control socket | |
| 6 | TUI | |
| 7 | Copy and export — visual select, OSC 52 | |
| 8 | Per-process CPU, memory, disk I/O | |

Steps 1–3 are the point at which this replaces `make dev` for its author.

## Design decisions

The non-obvious choices are written down, with the reasoning that produced them:

- [Logs travel through the filesystem, not the control socket](docs/adr/0001-logs-through-the-filesystem.md)
- [Read process-compose.yaml rather than defining our own format](docs/adr/0002-read-process-compose-yaml.md)
- [Zig, not Rust](docs/adr/0003-zig-over-rust.md) — the score was near-even, and the tiebreaker was not technical
- [Portable by construction, Linux-only by scope](docs/adr/0004-portability-posture.md)

[`CONTEXT.md`](CONTEXT.md) is the glossary — what a Worker, a Group, a Gate, an
Archive, and a Window each mean here, and which words are deliberately avoided.

## Credits

- **[process-compose](https://github.com/F1bonacc1/process-compose)** by Eugene Berger — the tool this starts from, and whose config file it reads.
- **[mandor](https://github.com/asyafalni/mandor)** by Alfin Syafalni — a PID-1 container supervisor in Zig. Different shape, same problems; read closely, and borrowed from per-function with attribution.
- **[zig-yaml](https://github.com/kubkon/zig-yaml)** by Jakub Konka — vendored under `src/vendor/yaml`. See its [PROVENANCE.md](src/vendor/yaml/PROVENANCE.md) for why it is vendored and what is patched.

## License

MIT — see [LICENSE](LICENSE).
