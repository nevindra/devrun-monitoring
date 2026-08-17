<div align="center">

# devrun

**A process runner for local development whose logs your coding agent can actually read.**

[![release](https://img.shields.io/github/v/release/nevindra/devrun-monitoring?label=release&color=2b2b2b)](https://github.com/nevindra/devrun-monitoring/releases)
[![license](https://img.shields.io/badge/license-MIT-2b2b2b)](LICENSE)
[![platform](https://img.shields.io/badge/linux-x86__64%20%C2%B7%20aarch64-2b2b2b)](#install)
[![binary](https://img.shields.io/badge/binary-0.6%20MB-2b2b2b)](#measured-against-process-compose)
[![rss](https://img.shields.io/badge/idle%20RSS-1.2%20MB-2b2b2b)](#measured-against-process-compose)
[![zig](https://img.shields.io/badge/zig-0.16-2b2b2b)](https://ziglang.org/download/#release-0.16.0)

[Install](#install) · [Set it up for an agent](#two-commands-to-set-it-up) · [What the agent gets back](#the-four-questions-an-agent-can-now-ask) · [Token cost](#what-it-costs-to-read) · [The TUI](#for-the-human-at-the-keyboard) · [vs process-compose](#measured-against-process-compose)

</div>

---

devrun starts every service in your repo's `process-compose.yaml`, keeps each
one's output in a plain file on disk, and answers questions about all of them in
one command. Four commands are the whole interface:

```console
$ devrun up --detach      # start everything, return once all are ready
$ devrun errors           # did anything break, and the log under it
$ devrun logs --since 2m  # every service's output, merged by time
$ devrun down             # stop everything
```

**Status: working.** Spawns, supervises, archives, probes, draws, and answers
questions about all of it. Linux only, Zig 0.16, one static binary, nothing to
fetch at runtime.

## Your agent is reading one log out of four

Ask a coding agent to fix a failing request. It runs `pnpm dev` in the
background and gets that one process's output back. Then it starts guessing,
because the error is in the worker. Or the database. Or the thing that failed to
bind a port before either of them started.

Nothing in its toolbox lets it ask *"what did everything say while that request
was failing"*. So it reads one log, guesses wrong, and comes back to ask you.

devrun answers that question, because it never had the logs anywhere else.
**Every process writes to a plain file from the moment it spawns.** The TUI is a
view over those files, not their owner.

```
                  ┌─ .devrun/logs/<name>.log ──→ tail · grep · less · $EDITOR
process ──stdout──┤                          ──→ devrun logs · errors
                  ├─ .devrun/logs/<name>.idx ──→ when each chunk was written
                  └─ in-memory window (1 MB)  ──→ TUI, scrolls past it via pread

.devrun/control.sock ──→ start · stop · restart · status · samples · down
                                                            (never logs)
```

Two things follow from that shape. Logs never cross the socket, so the socket
stays a trivial line protocol with no framing, no subscriptions, no backpressure.
And the in-memory window is a bounded cache rather than the record, so scrolling
past it reads from the page cache at RAM speed without counting toward RSS.

## Install

```console
$ curl -fsSL https://raw.githubusercontent.com/nevindra/devrun-monitoring/main/install.sh | sh
```

Static x86_64 and aarch64 binaries, checked against the release's `SHA256SUMS`
before anything is written, and renamed into place rather than written over.
Lands in `~/.local/bin`; `DEVRUN_INSTALL_DIR` overrides.

```console
$ devrun update              # replace this binary with the latest release
$ devrun version
```

`devrun update` runs that same install script rather than reimplementing it, and
replaces whichever binary you invoked. A build in `~/src` and a release in
`~/.local/bin` do not overwrite each other.

**From source**, with [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0):

```console
$ zig build && zig build test
$ ./zig-out/bin/devrun up
```

## Two commands to set it up

```console
$ cd your-repo
$ devrun init
```

That is it. `devrun init` writes a short section into your repo's `AGENTS.md`,
or `CLAUDE.md`, whichever the repo already has, between `<!-- devrun:begin -->`
markers. Re-running it replaces the block instead of stacking copies, and
anything you wrote around it survives.

**This is the step that makes the rest reachable.** An agent reads that file
before it does anything. A tool that is not named there does not exist to it,
however good the tool is. The block is four commands and the flags worth
knowing, kept short on purpose: it lands in a file that is paid for on every
single turn.

If your repo has no `process-compose.yaml`, skip straight to
[one command, no config file](#one-command-no-config-file). devrun still works.

## The four questions an agent can now ask

Every block below is real output from a four-service session: `db`, `api`, `web`,
and a `worker` that panics.

### "Did anything break?"

```console
$ devrun errors
devrun: 1 of 4 processes broken.

worker  failed  exit 2
  23:39:14 starting worker
  23:39:15 panic: runtime error: invalid memory address

devrun: 1 error-shaped line from processes that are still up.
  23:39:16 api ERROR upstream refused connection
$ echo $?
1
```

**252 bytes.** One call. It names what is broken, gives the exit code, prints
the tail of that process's log, and then sweeps everything still standing for
the failure that has not taken a process down yet. That last line is the one an
agent would never have found: `api` is still running, still reporting healthy,
and already refusing upstream connections.

Without it, the same answer costs a `status` call plus one `logs` call per
service, and most of the time those calls come back to say nothing is wrong.

### "What happened in the last two minutes?"

```console
$ devrun logs --since 2m
23:39:14 db     LOG:  connection accepted
23:39:14 web    VITE ready in 312 ms
23:39:14 worker starting worker
23:39:14 web    [vite] page reload src/App.tsx ×5
23:39:14 api    INFO 2026-08-18T22:00:01Z request GET /api/items 200 4ms ×3
23:39:14 db     LOG:  connection accepted
23:39:15 worker panic: runtime error: invalid memory address
23:39:15 db     LOG:  connection accepted
23:39:16 api    ERROR upstream refused connection
23:39:16 db     LOG:  connection accepted ×3
devrun: 8 repeats folded.
```

Every process, interleaved in the order things actually happened. That ordering
is the view a single dev server in a single terminal cannot give you, and it is
what makes the panic in `worker` and the refusal in `api` legible as one story.

### "Show me only the failures"

```console
$ devrun logs --grep 'panic|ERROR'
23:39:15 worker panic: runtime error: invalid memory address
23:39:16 api    ERROR upstream refused connection
```

`--grep` and `--tail` compose the way you would want.
`devrun logs --grep ERROR --tail 5` gives the last five **matches**, not the
matches among the last five lines. The second reading would report a clean log
for a service that has been failing all morning.

### "Give me that as data"

```console
$ devrun status --json
{"name":"db","state":"running","restarts":0,"bytes":156,"uptime_ms":4006,"broken":false}
{"name":"api","state":"running","restarts":0,"bytes":205,"uptime_ms":4005,"broken":false}
{"name":"web","state":"running","restarts":0,"bytes":176,"uptime_ms":4005,"broken":false}
{"name":"worker","state":"failed","restarts":0,"bytes":61,"exit":"exit:2","broken":true}

$ devrun logs --grep 'panic|ERROR' --json
{"ts":1787009955134,"w":"worker","msg":"panic: runtime error: invalid memory address"}
{"ts":1787009956136,"w":"api","msg":"ERROR upstream refused connection"}
```

One ndjson object per line, timestamps in epoch milliseconds. `status --json`
carries a `broken` flag so nothing has to be pattern-matched out of prose.

### Exit codes, so a script never has to read a word

| command | exits non-zero when |
|---|---|
| `devrun up --detach` | a service failed to come up inside the timeout |
| `devrun wait --timeout 90s` | it is still not ready when the clock runs out |
| `devrun errors` | anything is broken right now |
| `devrun run CMD` | the command itself did, including `128 + signal` |

A process with a readiness probe does not count as ready until the probe says
so. "Running, and that is all it will ever be" and "running, probe has not
passed yet" are different answers, and the control socket reports which one a
process is in so that `wait` never has to guess or read the config to find out.

## What it costs to read

`devrun logs` drops what only a terminal was ever going to act on. Measured on a
dev workload with four services: a Vite reload loop, a rebuild loop, fifty
request log lines, a progress bar, and one minified bundle line.

| | lines | bytes |
|---|---|---|
| `cat .devrun/logs/*.log` | 153 | 19,880 |
| `devrun logs --all` | **6** | **1,447** |

**That is the same content, not a smaller slice of it.** Four things account for
the difference:

- ANSI escapes are stripped.
- A progress bar that rewrote itself in place shows only its final state.
- Runs of identical lines fold into `rebuilding… ×40`.
- A single line past 1200 bytes is clipped, with a count of what was cut.

**Nothing is dropped silently.** A note on stderr says how much was folded,
clipped, or left behind, and `--raw --all` puts every byte back:

```console
$ devrun logs
23:01:51 web     [vite] page reload src/App.tsx ×60
23:01:51 web     installing [####] 100%
23:01:51 api     INFO 2026-08-18T22:00:00Z request GET /api/items 200 4ms ×50
23:01:51 api     ERROR upstream refused connection
devrun: 147 repeats folded, 1 long line clipped.
```

The default is the last 100 lines, or 1000 with `--since`, because a command
that might dump a gigabyte has to be *known* to be safe before it is worth
running. `--all` lifts the limit.

## For the human at the keyboard

`devrun up` draws a TUI built around the three things people actually open one
for: read a log, take lines out of it, and see which process is working.

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

| key | what it does |
|---|---|
| drag, or `v` then `↑` / `↓` | pick lines |
| `y` | copy: the picked lines, or the visible pane |
| Esc | let the picked lines go |
| click, Tab, `n` / `p`, `←` / `→` | switch process |
| wheel, `j` / `k`, `↑` / `↓`, PgUp / PgDn | scroll |
| Home / End, `g` / `G` | jump to the start, or back to live |
| `s` / `r` / `S` | stop, restart, start this process |
| `?` | every key, spelled out |
| `q` | shut the Session down; again to leave immediately |

**Copy goes out over OSC 52**, so it lands on the clipboard of the machine you
are sitting at, through SSH and tmux. It takes whole lines, never the borders or
the table above. Because the mouse is being tracked, your terminal's own text
selection needs **Shift** held down.

**The box title over the log is the path it is being written to.** It stands
there the whole time rather than waiting to be asked for, because "can you send
me this?" is answered by a filename and that should not be something you have to
know to look up.

**The CPU column is a figure and a meter in one cell.** The number answers "how
much", the block beside it answers "which of these". That number counts the
processes a Worker has already buried, so a Worker that forks per unit of work
(`make`, `tsc`, a test runner) no longer reports 0% while pinning a core.

**Memory is the whole tree, not the process you launched**, which is why these
figures run larger than other runners report. A service started through `uv`,
`npm` or a shell wrapper puts almost nothing in that first process, so a tool
reporting only its RSS is showing you the launcher. `PROC` says how many
processes the figure covers, and the line under the table names the largest, so
a total can be checked rather than believed. It is PSS rather than summed RSS:
summing counts every shared page once per process, and four processes sharing
300 MB came to 1.3 GB that way.

Every state is said three ways at once, as a shape, a word, and a colour. None
of the three has to be the one that works, which is what keeps the view readable
in a mono terminal, in a pasted screenshot, and to a reader who cannot separate
two of the colours.

Piped or redirected, `up` prints prefixed lines instead of drawing, so
`devrun up | tee build.log` and CI both work.

<details>
<summary><b>The full command list</b></summary>

```console
$ devrun up                    # TUI
$ devrun up --detach           # background; returns once everything is ready
$ devrun run pnpm dev          # one command, no config file needed
$ devrun up --plain            # prefixed lines, no terminal control
$ devrun up --window-bytes 8M  # a larger in-memory cache; the log is unaffected
$ devrun config                # what devrun understood from the file
$ devrun logs                  # every process's output, merged by time
$ devrun logs api --path       # the Archive's path, because the log is a file
$ devrun errors                # what broke, and the log under it
$ devrun status                # ask a running Session what it is doing
$ devrun samples               # per-process CPU, memory, disk I/O
$ devrun restart api           # act on one Worker without stopping the rest
$ devrun wait --timeout 90s    # block until ready; non-zero if something failed
$ devrun down                  # shut the Session down from another terminal
$ devrun init                  # write the agent instructions into AGENTS.md
```

Run `devrun` with no arguments for every flag.

</details>

## One command, no config file

Most repos do not have a `process-compose.yaml`. Until `devrun run`, those were
repos where devrun did nothing at all.

```console
$ devrun run pnpm dev
$ devrun run go run ./cmd/api
$ devrun run --detach --ready-log "listening on" bun run dev
```

Anything you can type in a shell works, because the command goes to the shell
the same way a config-driven process does. What you get on top is the Archive
and the Index, and therefore `devrun logs`, `errors`, `status`, `wait` and
`--detach` on a command that had none of them.

`devrun run` exits with the command's own exit status, `128 + signal` included,
so it drops into a script or a Makefile as a wrapper.

Two rules about the words after `run`:

1. **They are passed through untouched.** `devrun run pnpm dev --json` gives
   `--json` to pnpm, and devrun's own flags go first.
2. **Each word is quoted for the shell** rather than joined with spaces, because
   your shell already split and unquoted them once. Without that,
   `devrun run node -e "print('a b')"` would arrive as two arguments and fail in
   a way that looks like node's fault. `--shell` turns it off when you want
   shell syntax: `devrun run --shell 'sleep 1; echo hi'`.

Flags: `--name`, `--cwd`, `--restart POLICY`, `--ready-log TEXT`.

It has to be `devrun run <cmd>`, never a bare `devrun <cmd>`. A bare form would
collide with every subcommand devrun has and every one it might grow: add a
`devrun test` later and `devrun test ./...` silently stops running your tests.
That is the same class of mistake the config loader refuses to make.

## It reads the config you already have

devrun reads your existing `process-compose.yaml`. No second config file,
nothing to keep in sync, and a teammate can keep running
[process-compose](https://github.com/F1bonacc1/process-compose) against the same
file.

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

<details>
<summary><b>The supported subset, field by field</b></summary>

| | |
|---|---|
| Top level | `version` (ignored), `shell.shell_command`, `shell.shell_argument` |
| Process | `command`, `description`, `working_dir`, `dotenv`, `environment`, `ready_log_line` |
| Dependencies | `depends_on.<name>.condition`, all five conditions |
| Restart | `availability.restart`: `no`, `always`, `on_failure`, `exit_on_failure` |
| Probes | `readiness_probe.exec.command`, `readiness_probe.http_get.{host,scheme,path,port}` |
| Probe timing | `initial_delay_seconds`, `period_seconds`, `timeout_seconds`, `success_threshold`, `failure_threshold` |
| Shutdown | `shutdown.signal`, `shutdown.timeout_seconds` |

`${VAR}` and `$VAR` expand over the raw file *before* YAML parsing, with `.env`
values taking precedence over the OS environment and unset names becoming empty.
That matches process-compose exactly. Shell parameter expansion
(`${VAR:-default}`) is rejected, as it is there. Omitted fields take
process-compose's defaults rather than zero: probes default to
`period_seconds: 10`, `timeout_seconds: 1`, `failure_threshold: 3`, and
`shutdown` to SIGTERM with a 10-second grace.

Two limits are ours rather than process-compose's. `readiness_probe.http_get`
speaks plain HTTP only (`scheme: https` is refused, not silently downgraded),
and its `host` must be an IP literal or `localhost`, because a name lookup in
the event loop is a blocking call wearing a disguise.

</details>

A config is also refused when its graph could never resolve: a `depends_on`
cycle, a `process_healthy` wait on a process with no probe, or a
`process_log_ready` wait on one with no `ready_log_line`. Each of those would
otherwise hang the Session with nothing on screen to say why.

Beyond the config, devrun runs the graph: all five `depends_on` conditions,
readiness probes over `exec` and `http_get`, the four restart policies, and a
shutdown ladder that honours the signal and grace period the file asks for.

## Measured against process-compose

Both runners were given the **same `process-compose.yaml`**, started in a pty of
the same size (160×40), and left to settle for four seconds before a
twenty-second measurement window. What is measured is the **supervisor's own**
CPU and RSS, meaning `utime + stime` and resident pages of that one process, not
the services it runs. Three runs each, interleaved; the spread was under 0.1
points.

process-compose v1.116.0, devrun at `ReleaseFast`, Linux 7.0, 16 cores.

| | devrun | process-compose |
|---|---|---|
| Idle, 4 services, CPU | **0.0 %** | 0.8 % |
| Idle, 4 services, RSS | **1.2 MB** | 66 MB |
| Log firehose, CPU | **0.7 %** | 1.5 % |
| Log firehose, RSS after 80 s | **1.2 MB, flat** | 61 → 69 MB |
| Time to first byte on the terminal | **0.7 ms** | 16 ms |
| Binary on disk | **0.6 MB** | 45 MB |

The firehose is one service writing ~80 KB/s of JSON-ish log lines while three
sit idle. Over that run devrun put **3.1 MB of log on disk in 40 seconds while
holding 1.2 MB resident, and the figure never moved.** That is the design claim
rather than a coincidence: the Window is a fixed cache and the Archive is the
file.

**One number goes the other way, and it is worth knowing.** Under the firehose
devrun writes ~510 KB/s to the terminal against process-compose's 27 KB/s. It
redraws as output arrives, capped at 62 frames a second, where process-compose
repaints on a fixed slower cadence. That is a deliberate trade, the log on
screen is current, but on a thin SSH link it is bandwidth you are spending.

Read the rest of the table with the scope in mind. process-compose is
cross-platform, has a REST API, a far larger config surface, and years of edge
cases devrun has not met yet. devrun reads a strict subset of one file on one
OS. It *should* be cheaper. The point of measuring was to check that it actually
is, and by how much. To repeat any of this: the harness is a `pty.fork`, a fixed
`TIOCSWINSZ`, and `/proc/<pid>/stat` sampled at both ends of the window.

## Questions people ask

**Does this replace process-compose?**
No. It reads its config file and runs a strict subset of it, on Linux, cheaply.
A teammate on macOS keeps running process-compose against the same file.

**Why is there no MCP server?**
Every coding agent already has a shell, and
`devrun logs --since 2m --grep error` is one call. An MCP server would be a
protocol, a process, and a schema to keep in sync in order to offer the same
thing. If that turns out to be wrong it is a small thing to add later; adding it
now would be a subsystem bet made on a guess.

**Does it work on macOS?**
Not yet. Nothing is built that would have to be torn out to add it: the event
loop is `poll()` with a self-pipe rather than `epoll` with `signalfd`, and the
resource accounting sits behind one narrow backend interface. See
[ADR 0004](docs/adr/0004-portability-posture.md) for what a port costs and what
it would give up.

**Does it leave anything behind?**
One directory, `.devrun/`, beside your config: the log files, the control
socket, and the detached Session's own output. No daemon, no runtime, no second
config file in your repo.

**What if my logs are enormous?**
The Archive on disk keeps everything, byte-faithful. The in-memory Window is
1 MB across all processes by default (`--window-bytes` to change it), and
scrolling past it reads the file with `pread`. RSS does not follow log volume.

## Design decisions

Everything in the original plan is done: config, spawn and shutdown ladder,
Archive and Window, state machine and probes, control socket, TUI, copy, and
per-process sampling. Not done, and deliberately so: log search in the TUI,
`liveness_probe`, and anything that would put a second config file in the repo.

The non-obvious choices are written down with the reasoning that produced them:

- [Logs travel through the filesystem, not the control socket](docs/adr/0001-logs-through-the-filesystem.md)
- [Read process-compose.yaml rather than defining our own format](docs/adr/0002-read-process-compose-yaml.md)
- [Zig, not Rust](docs/adr/0003-zig-over-rust.md). The score was near-even, and the tiebreaker was not technical.
- [Portable by construction, Linux-only by scope](docs/adr/0004-portability-posture.md)
- [Render log bytes straight through, not through a cell grid](docs/adr/0005-render-log-bytes-through.md). Why the TUI is hand-written, against 0003.
- [Time lives beside the bytes, in a sidecar](docs/adr/0006-time-beside-the-bytes.md). How `--since` and merging work without touching the Archive.

[`CONTEXT.md`](CONTEXT.md) is the glossary: what a Worker, a Group, a Gate, an
Archive, and a Window each mean here, and which words are deliberately avoided.
[`CHANGELOG.md`](CHANGELOG.md) says what changed for someone using devrun.

## Credits

- **[process-compose](https://github.com/F1bonacc1/process-compose)** by Eugene Berger. The tool this starts from, and whose config file it reads.
- **[mandor](https://github.com/asyafalni/mandor)** by Alfin Syafalni. A PID-1 container supervisor in Zig. Different shape, same problems; read closely, and borrowed from per-function with attribution.
- **[zig-yaml](https://github.com/kubkon/zig-yaml)** by Jakub Konka. Vendored under `src/vendor/yaml`, and the only dependency. See its [PROVENANCE.md](src/vendor/yaml/PROVENANCE.md) for why it is vendored and what is patched.

## License

MIT. See [LICENSE](LICENSE).
