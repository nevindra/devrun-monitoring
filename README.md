# devrun

A process runner for local development whose logs you can actually get out of it.

> **Status: working.** Spawns, supervises, archives, probes, and draws.
> See [Roadmap](#roadmap) for what is done. Linux only, Zig 0.16, no
> dependencies to fetch.

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
                  └─ in-memory window (1 MB)  ──→ TUI, scrolls past it via pread

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
| Process | `command`, `description`, `working_dir`, `dotenv`, `environment`, `ready_log_line` |
| Dependencies | `depends_on.<name>.condition` — all five conditions |
| Restart | `availability.restart` — `no`, `always`, `on_failure`, `exit_on_failure` |
| Probes | `readiness_probe.exec.command`, `readiness_probe.http_get.{host,scheme,path,port}` |
| Probe timing | `initial_delay_seconds`, `period_seconds`, `timeout_seconds`, `success_threshold`, `failure_threshold` |
| Shutdown | `shutdown.signal`, `shutdown.timeout_seconds` |

`${VAR}` and `$VAR` expand over the raw file *before* YAML parsing, with `.env`
values taking precedence over the OS environment and unset names becoming empty
— matching process-compose exactly. Shell parameter expansion (`${VAR:-default}`)
is rejected, as it is there.

Omitted fields take process-compose's defaults, not zero: probes default to
`period_seconds: 10`, `timeout_seconds: 1`, `failure_threshold: 3`,
`http_get` defaults to `127.0.0.1`, `http`, `/`, and `shutdown` defaults to
SIGTERM with a 10-second grace.

A config is also refused when its graph could never resolve — a `depends_on`
cycle, a `process_healthy` wait on a process with no probe, or a
`process_log_ready` wait on one with no `ready_log_line`. Each of those would
otherwise hang the Session with nothing on screen to say why.

Two limits are ours rather than process-compose's: `readiness_probe.http_get`
speaks plain HTTP only (`scheme: https` is refused, not silently downgraded)
and its `host` must be an IP literal or `localhost`, because a name lookup in
the event loop is a blocking call wearing a disguise.

## Try it

Requires [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0).

```console
$ zig build
$ zig build test
$ ./zig-out/bin/devrun up
```

`devrun up` starts everything and draws the TUI. Piped or redirected, it prints
prefixed lines instead, so `devrun up | tee build.log` and CI both work.

```console
$ devrun up                  # TUI
$ devrun up --plain          # prefixed lines, no terminal control
$ devrun up --window-bytes 8M  # a larger in-memory cache; the log is unaffected
$ devrun config              # what devrun understood from the file
$ devrun logs api            # prints the Archive's path — the log is a file
$ devrun status              # ask a running Session what it is doing
$ devrun samples             # per-process CPU, memory, disk I/O
$ devrun restart api         # act on one Worker without stopping the rest
```

`devrun config` parses a file and prints what devrun understood from it — useful
on its own for checking that a config says what you think it says.

### In the TUI

| | |
|---|---|
| `n` / `p`, `←` / `→` | select a process |
| `j` / `k`, `↑` / `↓`, PgUp / PgDn | scroll its log |
| `g` / `G`, Home / End | jump to the top, or back to following the tail |
| `v` then `↑` / `↓` | select lines |
| `y` | copy — the selection, or the visible pane if there is none |
| `s` / `r` / `S` | stop, restart, start the selected process |
| `q` | shut the Session down; again to leave immediately |

Copy uses OSC 52, so it reaches your real clipboard through SSH and tmux. And
scrolling back past the in-memory Window reads the Archive with `pread`, which
for anything written this Session is the page cache — so the scrollback is the
whole run, not the last few megabytes.

That fallback is why the Window is only a megabyte. It is a cache in front of
the file, not the record, and a page-cache read runs at the speed of the memcpy
it replaces — so a bigger Window buys nothing you can measure and costs RSS on
exactly the Worker that is noisiest. `--window-bytes` is there if you disagree.

## Roadmap

| | | |
|---|---|---|
| 1 | Config — parse, expand, validate | **done** |
| 2 | Spawn, process groups, shutdown ladder | **done** |
| 3 | Log archive on disk + bounded memory window | **done** |
| 4 | State machine, dependency graph, readiness probes | **done** |
| 5 | Control socket | **done** |
| 6 | TUI | **done** |
| 7 | Copy and export — visual select, OSC 52 | **done** |
| 8 | Per-process CPU, memory, disk I/O | **done** |

Not done, and deliberately: log search in the TUI, `liveness_probe`, and
anything that would put a second config file in the repo.

## Design decisions

The non-obvious choices are written down, with the reasoning that produced them:

- [Logs travel through the filesystem, not the control socket](docs/adr/0001-logs-through-the-filesystem.md)
- [Read process-compose.yaml rather than defining our own format](docs/adr/0002-read-process-compose-yaml.md)
- [Zig, not Rust](docs/adr/0003-zig-over-rust.md) — the score was near-even, and the tiebreaker was not technical
- [Portable by construction, Linux-only by scope](docs/adr/0004-portability-posture.md)
- [Render log bytes straight through, not through a cell grid](docs/adr/0005-render-log-bytes-through.md) — why the TUI is hand-written, against 0003

[`CONTEXT.md`](CONTEXT.md) is the glossary — what a Worker, a Group, a Gate, an
Archive, and a Window each mean here, and which words are deliberately avoided.

## Credits

- **[process-compose](https://github.com/F1bonacc1/process-compose)** by Eugene Berger — the tool this starts from, and whose config file it reads.
- **[mandor](https://github.com/asyafalni/mandor)** by Alfin Syafalni — a PID-1 container supervisor in Zig. Different shape, same problems; read closely, and borrowed from per-function with attribution.
- **[zig-yaml](https://github.com/kubkon/zig-yaml)** by Jakub Konka — vendored under `src/vendor/yaml`, and the only dependency. See its [PROVENANCE.md](src/vendor/yaml/PROVENANCE.md) for why it is vendored and what is patched.

## License

MIT — see [LICENSE](LICENSE).
