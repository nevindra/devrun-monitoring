# devrun

A process runner for local development whose logs you can actually get out of it.

> **Status: working.** Spawns, supervises, archives, probes, and draws.
> Linux only, Zig 0.16, no dependencies to fetch.

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

## Install

```console
$ curl -fsSL https://raw.githubusercontent.com/nevindra/devrun-monitoring/main/install.sh | sh
```

Static x86_64 and aarch64 binaries, checked against the release's `SHA256SUMS`
before anything is written and renamed into place rather than written over.
Lands in `~/.local/bin`; `DEVRUN_INSTALL_DIR` overrides.

```console
$ devrun update              # replace this binary with the latest release
$ devrun version
```

`devrun update` runs that same script rather than reimplementing it, and
replaces whichever binary you invoked — a build in `~/src` and a release in
`~/.local/bin` do not overwrite each other.

**From source** — requires [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0):

```console
$ zig build && zig build test
$ ./zig-out/bin/devrun up
```

## What it does

**Runs the processes.** Reads your existing `process-compose.yaml`. Dependency
graph with all five `depends_on` conditions, readiness probes over `exec` and
`http_get`, the four restart policies, and a shutdown ladder that honours the
signal and grace period the file asks for.

**Keeps the logs.** `.devrun/logs/<name>.log` is a plain file, byte-faithful,
ANSI intact, being appended to while the Session runs. Scrollback goes to the
start of the run rather than to the end of a buffer.

**Gets lines out.** Drag across the log to pick lines, `y` to copy. Copy goes
over OSC 52, so it lands on the clipboard of the machine you are sitting at,
through SSH and tmux. Excerpts go out as plain text.

**Says what each process is doing.** Per-Worker CPU, memory and disk I/O over
the whole process tree — the CPU figure counts children already reaped, and the
memory figure is PSS so a tree's total is not the same page counted five times.

**Stays out of the way.** One static binary, no runtime, no daemon left behind,
no second config file in your repo.

```console
$ devrun up                    # TUI
$ devrun up --plain            # prefixed lines, no terminal control
$ devrun up --window-bytes 8M  # a larger in-memory cache; the log is unaffected
$ devrun config                # what devrun understood from the file
$ devrun logs api              # prints the Archive's path — the log is a file
$ devrun status                # ask a running Session what it is doing
$ devrun samples               # per-process CPU, memory, disk I/O
$ devrun restart api           # act on one Worker without stopping the rest
```

Piped or redirected, `up` prints prefixed lines instead of drawing, so
`devrun up | tee build.log` and CI both work.

## Coexistence

devrun reads your existing `process-compose.yaml` — no second config file,
nothing to keep in sync. It supports a strict subset of the schema and
**refuses any field it does not understand** rather than ignoring it. That
refusal is deliberate: a silently skipped field is how two people run the same
file and get different behaviour with nothing on screen to say why.

```console
$ devrun config
devrun: processes.go: unsupported field "log_location". devrun reads a subset of
process-compose's schema and refuses fields it would otherwise ignore, so that
both tools read this file the same way.
```

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
is rejected, as it is there. Omitted fields take process-compose's defaults, not
zero: probes default to `period_seconds: 10`, `timeout_seconds: 1`,
`failure_threshold: 3`, and `shutdown` to SIGTERM with a 10-second grace.

A config is also refused when its graph could never resolve — a `depends_on`
cycle, a `process_healthy` wait on a process with no probe, or a
`process_log_ready` wait on one with no `ready_log_line`. Each would otherwise
hang the Session with nothing on screen to say why.

Two limits are ours rather than process-compose's: `readiness_probe.http_get`
speaks plain HTTP only (`scheme: https` is refused, not silently downgraded)
and its `host` must be an IP literal or `localhost`, because a name lookup in
the event loop is a blocking call wearing a disguise.

## In the TUI

The view is built around the three things people actually open it for: read a
log, take lines out of it, and see which process is working.

```
 devrun  athena-new                     3 of 4 running   RAM 3.2 GB   CPU 12.4%
┌─ services ──────────────────────────────────────────────────────────────────┐
│   NAME    STATUS     UPTIME    MEMORY  PROC      CPU RESTARTS      EXIT     │
│ ◉ go      ready      2m 14s    1.3 GB     6 ▁   1.2%        -         -     │
│ ● ui      running    2m 14s    304 MB     4     0.0%        1         -     │
│ ● parser  running    2m 13s    1.6 GB     4 █  99.8%        -         -     │
│ ✗ worker  failed         12s        -     -        -        3    killed     │
│  memory  1.3 GB across 6 processes   firecracker 874 MB   go 58 MB …        │
├─ go  .devrun/logs/go.log ───────────────────────────────────────────────────┤
│  {"time":"09:31:33","level":"info","msg":"migrations up to date"}           │
│▌ {"time":"09:31:33","level":"warn","msg":"embedding provider not set"}      │
│▌ {"time":"09:31:33","level":"info","msg":"storage connected"}               │
└─────────────────────────────────────────────────────────────────────────────┘
   ↑ picked lines
```

| | |
|---|---|
| drag, or `v` then `↑` / `↓` | pick lines |
| `y` | copy — the picked lines, or the visible pane |
| Esc | let the picked lines go |
| click, Tab, `n` / `p`, `←` / `→` | switch process |
| wheel, `j` / `k`, `↑` / `↓`, PgUp / PgDn | scroll |
| Home / End, `g` / `G` | jump to the start, or back to live |
| `s` / `r` / `S` | stop, restart, start this process |
| `?` | every key, spelled out |
| `q` | shut the Session down; again to leave immediately |

The log gets the full width because that is what it is for — a JSON line or a
stack trace is long. The box title over it is the path it is being written to,
standing there the whole time rather than waiting to be asked for: "can you send
me this?" is answered by a filename, and that should not be something you have
to know to look up.

Because the mouse is being tracked, your terminal's own text selection needs
**Shift** held down. devrun's copy is the better tool for it anyway: it takes
whole lines, never the borders or the table above, and reaches the real
clipboard.

**The CPU column is a figure and a meter in one cell** — the number answers "how
much", the block beside it answers "which of these". That number counts the
processes a Worker has already buried, so a Worker that forks per unit of work
(`make`, `tsc`, a test runner) no longer reports 0% while pinning a core.

**Memory is the whole tree, not the process you launched**, which is why these
figures run larger than other runners report. A service started through `uv`,
`npm` or a shell wrapper puts almost nothing in that first process; a tool
reporting only its RSS is showing you the launcher. `PROC` says how many
processes the figure covers and the line under the table names the largest, so
a total can be checked rather than believed. It is PSS rather than summed RSS,
because summing counts every shared page once per process — four processes
sharing 300 MB came to 1.3 GB that way.

Every state is said three ways at once: a shape, a word, and a colour. None of
the three has to be the one that works, which is what keeps the view readable in
a mono terminal, in a pasted screenshot, and to a reader who cannot separate two
of the colours.

Both of those sampling decisions are written up in
[ADR 0004](docs/adr/0004-portability-posture.md) — CPU is read per-pid, and PSS
is read on a rotation because it is 390× dearer than the CPU read and memory
moves slowly enough that a few seconds of lag costs a reader nothing.

## Measured against process-compose

Both runners were given the **same `process-compose.yaml`**, started in a pty of
the same size (160×40), and left to settle for four seconds before a
twenty-second measurement window. What is measured is the **supervisor's own**
CPU and RSS — `utime + stime` and resident pages of that one process — not the
services it runs. Three runs each, interleaved; the spread was under 0.1 points.

process-compose v1.116.0, devrun at `ReleaseFast`, Linux 7.0, 16 cores.

| | devrun | process-compose |
|---|---|---|
| Idle, 4 services — CPU | **0.0 %** | 0.8 % |
| Idle, 4 services — RSS | **1.2 MB** | 66 MB |
| Log firehose — CPU | **0.7 %** | 1.5 % |
| Log firehose — RSS after 80 s | **1.2 MB, flat** | 61 → 69 MB |
| Time to first byte on the terminal | **0.7 ms** | 16 ms |
| Binary on disk | **0.6 MB** | 45 MB |

The firehose is one service writing ~80 KB/s of JSON-ish log lines while three
sit idle. Over that run devrun put **3.1 MB of log on disk in 40 seconds while
holding 1.2 MB resident, and the figure never moved** — the design claim rather
than a coincidence: the Window is a fixed cache and the Archive is the file.

**One number goes the other way, and it is worth knowing.** Under the firehose
devrun writes ~510 KB/s to the terminal against process-compose's 27 KB/s. It
redraws as output arrives, capped at 62 frames a second, where process-compose
repaints on a fixed slower cadence. That is a deliberate trade — the log on
screen is current — but on a thin SSH link it is bandwidth you are spending.

Read the rest of the table with the scope in mind. process-compose is
cross-platform, has a REST API, a far larger config surface, and years of edge
cases devrun has not met yet. devrun reads a strict subset of one file on one
OS. It should be cheaper; the point of measuring was to check that it actually
is, and by how much. To repeat any of this: the harness is a `pty.fork`, a fixed
`TIOCSWINSZ`, and `/proc/<pid>/stat` sampled at both ends of the window.

## Design decisions

Everything in the original plan is done — config, spawn and shutdown ladder,
Archive and Window, state machine and probes, control socket, TUI, copy, and
per-process sampling. Not done, and deliberately: log search in the TUI,
`liveness_probe`, and anything that would put a second config file in the repo.

The non-obvious choices are written down with the reasoning that produced them:

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
