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

## What it does

**Runs the processes.** Reads your existing `process-compose.yaml`. Dependency
graph with all five `depends_on` conditions, readiness probes over `exec` and
`http_get`, the four restart policies, and a shutdown ladder that honours the
signal and grace period the file asks for.

**Keeps the logs.** Every process writes to `.devrun/logs/<name>.log` from the
moment it spawns — a plain file, byte-faithful, ANSI intact. `tail -f`, `grep`,
`less` and your editor work on it while the Session is running. The TUI is a
view over those files, not their owner, and scrollback goes to the start of the
run rather than to the end of a buffer.

**Gets lines out.** Drag across the log to pick lines, `y` to copy. Copy goes
over OSC 52, so it lands on the clipboard of the machine you are sitting at,
through SSH and tmux. Excerpts go out as plain text.

**Says what each process is doing.** Per-Worker CPU, memory and disk I/O over
the whole process tree — the CPU figure counts children already reaped, and the
memory figure is PSS so a tree's total is not the same page counted five times.

**Stays out of the way.** One static binary, no runtime, no daemon left behind,
no second config file in your repo. Piped or redirected it prints prefixed
lines instead of drawing, so `devrun up | tee build.log` and CI both work.

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

The log gets the full width because that is what it is for — a JSON line or a
stack trace is long, and the columns a list of names was holding onto were
columns the content needed.

**Drag across the log** to pick the lines you want, then `y` to copy them. With
nothing picked, `y` takes what is on screen. Click a process to switch to it,
and roll the wheel to scroll. `?` lists everything.

The box title over the log is the path it is being written to, standing there
the whole time rather than waiting to be asked for — "can you send me this?" is
answered by a filename, and that should not be something you have to know to
look up.

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

The CPU column is a figure and a **meter** in one cell: the number answers "how
much", and the block beside it answers "which of these", which is the question
you actually have when reading down a column of them.

That number counts the processes a Worker has already buried, not just the ones
alive at the instant it was sampled. A Worker that forks per unit of work —
`make`, `tsc`, a test runner — used to report 0% while pinning a core, because
most of its children were born and reaped between two ticks. See
[ADR 0004](docs/adr/0004-portability-posture.md#amendment-cpu-is-read-per-pid-and-no-longer-through-the-accumulator).

**Memory is the whole tree, not the process you launched**, which is why the
figures here are larger than other runners report — often by a lot. A service
started through `uv`, `npm` or a shell wrapper puts almost nothing in that
first process; a tool that reports only its RSS is showing you the launcher.
`PROC` says how many processes the figure covers, and the line under the table
names the largest of them, so a total can be checked rather than believed.

It is PSS rather than summed RSS, because summing RSS counts every page shared
between a parent and its forks once per process — four processes sharing 300 MB
came to 1.3 GB that way. PSS is read for a few processes per tick rather than
all of them every tick: it is 390× dearer than the CPU read, and memory moves
slowly enough that a few seconds of lag costs a reader nothing. See
[ADR 0004](docs/adr/0004-portability-posture.md#amendment-memory-is-pss-read-on-a-rotation).

Every state is said three ways at once: a shape, a word, and a colour. None of
the three has to be the one that works, which is what keeps the view readable
in a mono terminal, in a pasted screenshot, and to a reader who cannot separate
two of the colours.

Because the mouse is being tracked, your terminal's own text selection needs
**Shift** held down. devrun's copy is the better tool for it anyway: it takes
whole lines, never the borders or the table above, and reaches the real
clipboard.

Copy uses OSC 52, so it arrives on the clipboard of the machine you are sitting
at, through SSH and tmux. An Excerpt goes out as **plain text** — the Archive
stays byte-faithful with its ANSI intact, and `less` and `grep` still see every
escape, but a clipboard has no colours to put them in and `ESC[31m` in front of
a stack trace is four characters of litter in a chat window.

Scrolling back past the in-memory Window reads the Archive with `pread`, which
for anything written this Session is the page cache — so the scrollback is the
whole run, not the last few megabytes.

That fallback is why the Window is only a megabyte. It is a cache in front of
the file, not the record, and a page-cache read runs at the speed of the memcpy
it replaces — so a bigger Window buys nothing you can measure and costs RSS on
exactly the Worker that is noisiest. `--window-bytes` is there if you disagree.

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
holding 1.2 MB resident, and the figure never moved** — which is the design
claim rather than a coincidence: the Window is a fixed cache and the Archive is
the file. An idle Session is where the gap is widest, and an idle Session is
what a dev machine has open all afternoon.

**One number goes the other way, and it is worth knowing.** Under the firehose
devrun writes ~510 KB/s to the terminal against process-compose's 27 KB/s. It
redraws as output arrives, capped at 62 frames a second, where process-compose
repaints on a fixed slower cadence. That is a deliberate trade — the log on
screen is current — but on a thin SSH link it is bandwidth you are spending.

Read the rest of the table with the scope in mind. process-compose is
cross-platform, has a REST API, a far larger config surface, and years of
edge cases devrun has not met yet. devrun reads a strict subset of one file on
one OS. It should be cheaper; the point of measuring was to check that it
actually is, and by how much.

To repeat any of this: the harness is a `pty.fork`, a fixed `TIOCSWINSZ`, and
`/proc/<pid>/stat` sampled at both ends of the window.

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
