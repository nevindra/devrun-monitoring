<div align="center">

# devrun

**The dev process runner your coding agent can read.**

Start your whole stack from one `devrun.toml`. Every service's output lands in a plain file,
and one command answers "what broke?" across all of them.

[![version](https://img.shields.io/badge/version-0.2.0-2b2b2b)](CHANGELOG.md)
[![license](https://img.shields.io/badge/license-MIT-2b2b2b)](LICENSE)
[![platform](https://img.shields.io/badge/linux-x86__64%20%C2%B7%20aarch64-2b2b2b)](#install)
[![binary](https://img.shields.io/badge/binary-1.0%20MB-2b2b2b)](#what-you-get)
[![rss](https://img.shields.io/badge/idle%20RSS-~4%20MB-2b2b2b)](#what-you-get)
[![zig](https://img.shields.io/badge/zig-0.17-2b2b2b)](https://ziglang.org/download/#release-0.17.0)

[Install](#install) · [What you get](#what-you-get) · [Recipes](#recipes) · [Config](#the-config) · [For agents](#what-an-agent-can-ask) · [TUI](#the-tui) · [CLI](#cli-reference) · [FAQ](#faq)

</div>

---

## The 20-second taste

```toml
# devrun.toml
[services.db]
run   = "docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=dev postgres:16"
ready = { exec = "pg_isready -h localhost" }

[services.api]
run   = "pnpm dev"
after = ["db"]
ready = "http://localhost:3000/health"
```

```console
$ devrun up --detach      # start everything, return once all are ready
$ devrun errors           # did anything break, and the log under it
$ devrun logs --since 2m  # every service's output, merged by time
$ devrun down             # stop everything
```

**Why it matters.** Ask a coding agent to fix a failing request and it
backgrounds `pnpm dev`, then reads that one process's output. The error is in
the worker, or the database, or the port that failed to bind before either
started. The agent is reading one log out of four, so it guesses, and comes back
to ask you. With devrun it asks one question and gets the whole story.

## Install

```console
$ curl -fsSL https://raw.githubusercontent.com/nevindra/devrun-monitoring/main/install.sh | sh
```

Static x86_64 and aarch64 binaries, checked against the release's `SHA256SUMS`
before anything is written. Lands in `~/.local/bin` (`DEVRUN_INSTALL_DIR`
overrides). `devrun update` fetches the latest release later.

**The agent skill installs with it.** Next to the binary, the installer puts a
skill where your agent looks:

| Agent | Skill location |
|---|---|
| Claude Code | `~/.claude/skills/devrun` (when `~/.claude` exists) |
| Codex, OpenCode | `~/.agents/skills/devrun` |

An agent loads it only when a task is about running or debugging local services,
so it costs nothing the rest of the time. Skip it with `--no-skill` or
`DEVRUN_NO_SKILL=1`. `devrun skill install --to DIR` targets another agent's
folder; `devrun skill uninstall` removes it, and `devrun update` will not bring
it back.

**Per-repo instead of (or as well as):** `devrun init` writes a short block into
the repo's `AGENTS.md` or `CLAUDE.md` between `<!-- devrun:begin -->` markers.
Re-running replaces the block, and your own text around it survives. Good for
teammates without the skill.

**From source**, with [Zig 0.17.0](https://ziglang.org/download/#release-0.17.0):

```console
$ zig build && zig build test
$ ./zig-out/bin/devrun up
```

## What you get

| | | |
|---|---|---|
| **Merged logs** <br> Every service interleaved by time, so one failure reads as one story | **`errors` with exit codes** <br> Names what is broken, prints its log tail, sweeps healthy services for error lines | **Logs are plain files** <br> One directory per run under `.devrun/logs/`; `tail`, `grep` and your editor just work |
| **Cheap to read** <br> ANSI stripped, repeats folded, long lines clipped, always bounded | **Subsets and profiles** <br> `up NAME`, `--profile`, `--no-deps`, `start` later; the rest is `off`, not failed | **Watch to restart** <br> `watch = ["src"]` restarts a service when files change |
| **Replicas** <br> `replicas = 3` gives `worker.1` to `worker.3`, each with its own log | **Restart limits** <br> `max` and `backoff` stop a boot crash from looping forever | **One-command e2e** <br> `restart = "exit-on-end"` tears down the stack and exits with the suite's status |
| **Ready checks** <br> `http`, `exec` or `log`, with `after` waiting on them | **Stop commands** <br> `stop.command` cleans up daemons like `docker compose up -d` | **Local overrides** <br> `devrun.local.toml` for your ports and tokens, kept out of git |
| **A real TUI** <br> Service table, scrollable logs, line picking, copy over OSC 52 | **`devrun run CMD`** <br> Everything above for a single command, no config file | **Agent skill** <br> Installed with the binary, loaded only when relevant |
| **One static binary** <br> About 1.0 MB, nothing to fetch at runtime | **Tiny footprint** <br> About 4.4 MB RSS idle with 4 services, 0 CPU ticks over 10 idle seconds | **Typo-proof config** <br> Unknown fields are refused, with the right name suggested |

<sub>Footprint measured on 0.2.0, Linux, ReleaseFast, stripped: supervisor only, not the services it runs.</sub>

## Recipes

### A request is failing

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

$ devrun logs --grep 'panic|ERROR'
23:39:15 worker panic: runtime error: invalid memory address
23:39:16 api    ERROR upstream refused connection
```

`api` is still running and still looks healthy, yet it is already refusing
connections. `errors` finds that; `status` would not.

### An e2e run in one command

```toml
[profiles.e2e]
services = ["e2e"]                # plus everything it depends on

[services.e2e]
run       = "pnpm test:e2e"
after     = { api = "ready" }     # the suite waits for the API
autostart = false
restart   = "exit-on-end"         # when the suite ends, so does the Session
```

```console
$ devrun up --profile e2e --plain
```

It starts the stack, runs the suite, tears everything down, and **exits with the
suite's own exit status**. The logs survive the run.

### Working on one service

```console
$ devrun up api --detach     # api and what it depends on; the rest is off
$ devrun logs api --tail 50
$ devrun start worker        # bring another one in later
```

Add `watch = ["src"]` to `api` and saving a file restarts it.

### No config at all

```console
$ devrun run --detach --ready-log "listening on" pnpm dev
$ devrun errors
```

You get the logs, `errors`, `status`, `wait` and `--detach` on a command that had
none of them. Without `--detach` it blocks and exits with the command's own
status (`128 + signal` included), so it works as a wrapper in a script or
Makefile. Your words after `run` are passed through untouched, so
`devrun run pnpm dev --json` gives `--json` to pnpm; devrun's own flags go
first. `--shell` lets the shell parse them instead.

## The config

One file, `devrun.toml`, beside where you run devrun. The smallest is two lines:

```toml
[services.web]
run = "pnpm dev"
```

A realistic one: a database, a migration that must finish first, an API with a
health check, replicated workers, and an e2e suite.

```toml
env_file = ".env"                 # every service gets it

[env]                             # so does this
DATABASE_URL = "postgres://dev:dev@localhost:5432/app"

[templates.node]                  # shared settings, taken with `extends`
restart = { policy = "on-failure", max = 5, backoff = "1s" }
stop    = { signal = "INT", timeout = "15s" }

[profiles.e2e]                    # `devrun up --profile e2e`
services = ["e2e"]                # plus everything it depends on
env      = { BASE_URL = "http://localhost:3000" }

[services.postgres]
run   = ["docker", "run", "--rm", "-p", "5432:5432",
         "-e", "POSTGRES_PASSWORD=dev", "postgres:16"]
ready = { exec = "pg_isready -h localhost", every = "2s", failures = 30 }

[services.migrate]
run   = "pnpm db:migrate"
after = ["postgres"]              # waits for postgres to be ready

[services.api]
extends = "node"
run     = "pnpm dev"
cwd     = "apps/api"
env     = { PORT = 3000 }
after   = { migrate = "succeeded" }
ready   = "http://localhost:3000/health"
watch   = ["src"]                 # a change restarts it

[services.worker]
extends  = "node"
run      = "pnpm worker"
after    = ["api"]
ready    = { log = "worker started" }
replicas = 2                      # worker.1 and worker.2

[services.e2e]
run       = "pnpm test:e2e"
after     = { api = "ready" }
autostart = false                 # not part of a plain `devrun up`
restart   = "exit-on-end"         # when the suite ends, so does the Session
```

`devrun config` validates a file and prints what devrun understood. **Unknown
fields are refused, not ignored**, and the right name is suggested:

```console
$ devrun config
devrun: services.api: unknown field "command". devrun calls it "run"
```

A graph that could never resolve (an `after` cycle, a wait for `ready` on a
service with no check, a wait on a service that does not exist) is refused too,
instead of hanging the Session. The format is [TOML](https://toml.io/en/v1.0.0)
and the reasoning is in [ADR 0008](docs/adr/0008-devrun-toml.md).

<details>
<summary><b>Full field reference</b></summary>

| Top level | |
|---|---|
| `[services.<name>]` | Required. One table per service, shown in file order. Names use letters, digits, `-`, `_` and `.` |
| `[templates.<name>]` | Any service fields, taken by a service with `extends = "<name>"` |
| `[profiles.<name>]` | `services = ["api", "e2e"]` and optionally `env = { ... }`. `devrun up --profile <name>` starts those services and what they depend on, with that `env` layered over `[env]` |
| `[env]` | Variables every service gets |
| `env_file` | A file or a list of files every service reads, relative to the config |
| `shell` | What runs each command. Default `["bash", "-c"]` |
| `color` | Default `true`. Services get `FORCE_COLOR=1` and `CLICOLOR_FORCE=1`, so tools keep their colour in a pipe. `false` turns it off |

| Service | |
|---|---|
| `run` | Required. A string for the shell, or an array of words devrun quotes for it |
| `description` | Shown by `devrun config` |
| `cwd` | Working directory, relative to the config |
| `env` | `{ KEY = "value" }`. Numbers and booleans are written out as text |
| `env_file` | A file or a list of files |
| `after` | `["db"]`, or `{ db = "ready" }`. Conditions: `started`, `ready`, `exited`, `succeeded` |
| `autostart` | `false` keeps it out of a plain `devrun up` (it shows as `off`), unless a started service depends on it. `devrun start NAME` starts it later |
| `replicas` | `1` to `64`. N instances named `<name>.1` to `<name>.N`, each with `DEVRUN_REPLICA=<k>` in its environment |
| `watch` | `["src", "go.mod"]` or `{ paths = [...], ignore = [...], debounce = "300ms" }`. A change restarts the service |
| `restart` | `"no"` (default), `"always"`, `"on-failure"`, `"exit-on-failure"`, `"exit-on-end"`, or a table |
| `ready` | One of `http`, `exec` or `log` |
| `stop` | `{ signal = "INT", timeout = "15s", command = "..." }`. Default `TERM`, 10 s, then `KILL` |
| `extends` | The name of a template |

| `restart` table | |
|---|---|
| `policy` | The same names as the string form. `max` and `backoff` are only allowed with `always` or `on-failure` |
| `backoff` | Wait before the first restart, doubling each time up to 30 s (or the backoff itself, if longer). Default `200ms` |
| `max` | Give up after this many restarts in a row. The service is left `failed`, so `devrun errors` reports it. A run that stayed up 30 seconds resets the count |

| `stop` | |
|---|---|
| `signal` | A name (`"INT"` or `"SIGINT"`) or a number. Default `TERM` |
| `timeout` | Bounds the whole stop, command included, before `KILL`. Default 10 s |
| `command` | A string or an array, run with the service's env and cwd |

| `watch` table | |
|---|---|
| `paths` | Relative to the service's `cwd`. Directories are watched recursively |
| `ignore` | Names to skip, added to the defaults. `*` is a wildcard |
| `debounce` | Quiet time before a change counts, such as `"300ms"` |

| `ready` | |
|---|---|
| `http` | `"http://host:port/path"`. Plain HTTP; the host is an IP address or `localhost` |
| `status` | With `http` only. The exact status expected, such as `204`. Default: any 2xx or 3xx |
| `exec` | A command. Exit 0 is a pass |
| `log` | Text that, once it appears in the output, means ready |
| `delay`, `every`, `timeout` | For `http` and `exec`, in whole seconds: `5`, `"5s"`, `"2m"`. Defaults 0, 10 s, 1 s |
| `successes`, `failures` | Passes in a row to count as ready (1), failures in a row to report unhealthy (3) |

`ready = "http://..."` is the short form of `ready = { http = "..." }`.

**`after`.** `after = ["db"]` waits for `db` to be ready if it has a `ready`
check, and for it to have started if not. A service extending a template
overrides it field by field; `env` and `env_file` add up, and `stop` merges its
fields separately.

**Variables.** `${VAR}`, `$VAR` and `${VAR:-default}` expand in `env`,
`env_file`, `cwd` and `ready.http`, looking in the top-level `[env]`, then the
top-level `env_file`, then the environment devrun started in. `$$` is a dollar
sign. `run` and `ready.exec` are not expanded by devrun: they go to the shell as
written, so `awk '{print $NF}'` works.

**Layering.** A service's environment is the one devrun started in, then every
`env_file` in order, then every `env` entry. `env` beats `env_file`.

**Durations.** Probe timings and `stop.timeout` are whole seconds. `backoff` and
`debounce` also take milliseconds, such as `"300ms"`.

**Replicas.** Expanded when the config is built, so each replica has its own
`DEVRUN_REPLICA` and `${DEVRUN_REPLICA}` works in `env`, `env_file`, `cwd` and
`ready.http`:

```toml
[services.worker]
run      = "pnpm worker"
replicas = 3
env      = { PORT = "300${DEVRUN_REPLICA}" }
ready    = "http://127.0.0.1:300${DEVRUN_REPLICA}/health"
```

Each replica writes its own log, `.devrun/logs/latest/worker.2.log`.
`after = ["worker"]` waits for every replica, `after = ["worker.2"]` names one,
and on the command line `devrun logs worker` and `devrun restart worker` mean all
of them.

**Profiles and `off`.** A plain `devrun up` starts every service except those
with `autostart = false`. `--profile` and `up api web` start the named services
and what they depend on. Whatever was left out is `off`: not part of this run,
not a failure. `devrun wait` counts it as settled and `devrun errors` ignores
it. `devrun start NAME` brings one in later with its own off dependencies;
`--no-deps` starts only the names you gave and treats a dependency that is not
running as satisfied.

**Restart limits and `exit-on-end`.** `exit-on-end` is for "start the stack, run
the suite, tear it all down": when that service ends on its own, the whole
Session shuts down and devrun exits with its exit status. `max` stops a service
that crashes on boot from restarting forever.

**Stop commands.** `stop.command = "docker compose down"` runs whenever the
service is stopped (`devrun stop`, `down`, Ctrl-C, end of the Session), with the
service's env and cwd. If the service is still running afterwards it gets
`stop.signal`, and `stop.timeout` bounds the whole thing before `KILL`. It also
runs for a service that already exited, as long as it started this Session, which
is what lets a daemonising command like `docker compose up -d` clean up after
itself. Once the service's own output pipe has closed, the command's output goes
into that service's log.

**Watching.** A change under `watch` paths restarts the service, or starts it
again if it had exited or failed. Ignored by default (names you add under
`ignore` add to these): `.git`, `.devrun`, `node_modules`, `__pycache__`,
`.venv`, `.zig-cache`, `zig-out`, `*.swp`, `*.swx`, `*~`, `4913` and `.#*`. A
pattern matches a file or directory name. Uses Linux inotify; a path that cannot
be watched is reported when the Session starts.

**Colour.** Piped output makes most tools turn colour off, so devrun sets
`FORCE_COLOR=1` and `CLICOLOR_FORCE=1`. It does not when `NO_COLOR` is set in the
service's environment or with `color = false`, and a value you set in `env`
always wins. Colour costs an agent nothing: `devrun logs` strips escapes unless
you pass `--raw`.

**Local overrides.** If `devrun.local.toml` sits beside `devrun.toml` (for
`-f path/x.toml`, it is `path/x.local.toml`), it is merged over it: tables merge
key by key, anything else replaces. Use it for a port that clashes on your
machine or a token in `env`, and add it to `.gitignore`. `devrun config` says
when it merged one.

**Reserved.** `include` and `ready.tcp` are planned. Using one today gets a
message saying so rather than an unknown-field error.

</details>

## What an agent can ask

Real output from a four-service session: `db`, `api`, `web`, and a `worker`
that panics.

### Merged by time

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

`--grep` and `--tail` compose the way you would want:
`devrun logs --grep ERROR --tail 5` gives the last five **matches**, not the
matches among the last five lines.

### As data

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

One ndjson object per line, timestamps in epoch milliseconds, and a `broken`
flag so nothing is pattern-matched out of prose.

### Exit codes

| command | exits non-zero when |
|---|---|
| `devrun up --detach` | a service failed to come up inside the timeout |
| `devrun wait --timeout 90s` | it is still not ready when the clock runs out |
| `devrun errors` | anything is broken right now |
| `devrun run CMD` | the command itself did, including `128 + signal` |

A process with a ready check is not "ready" until the check passes, and the
control socket says which state it is in, so `wait` never has to guess.

### What it costs to read

`devrun logs` drops what only a terminal would act on. Measured on a four-service
dev workload (a Vite reload loop, a rebuild loop, fifty request lines, a progress
bar, one minified bundle line):

| | lines | bytes |
|---|---|---|
| `cat .devrun/logs/*.log` | 153 | 19,880 |
| `devrun logs --all` | **6** | **1,447** |

Same content, not a smaller slice: ANSI escapes are stripped, a progress bar that
rewrote itself shows only its final state, runs of identical lines fold into
`rebuilding… ×40`, and a line past 1200 bytes is clipped with a count of what was
cut. **Nothing is dropped silently.** A note on stderr says what was folded,
clipped or left behind, and `--raw --all` puts every byte back.

```console
$ devrun logs
23:01:51 web     [vite] page reload src/App.tsx ×60
23:01:51 web     installing [####] 100%
23:01:51 api     INFO 2026-08-18T22:00:00Z request GET /api/items 200 4ms ×50
23:01:51 api     ERROR upstream refused connection
devrun: 147 repeats folded, 1 long line clipped.
```

The default is the last 100 lines (1000 with `--since`), so a command that
might dump a gigabyte is known to be safe before it is run. `--all` lifts the
limit.

### How it works

```mermaid
flowchart LR
    P[process] -->|stdout| A[".devrun/logs/latest/name.log"]
    P -->|timestamps| I["name.idx"]
    P --> W["in-memory window, 1 MB"]
    A --> C["devrun logs, errors, tail, grep"]
    I --> C
    W --> T[TUI]
    S["control.sock"] -.->|start, stop, status, never logs| T
```

Every process writes to a plain file from the moment it spawns. The TUI is a view
over those files, not their owner, and logs never cross the control socket, which
stays a trivial line protocol. Every run gets its own directory with `latest`
aimed at the newest, so restarting to reproduce a bug does not delete the log of
the run you were reproducing. `devrun up` keeps the newest ten (`--keep N`
changes that, `--keep 0` keeps all), and `devrun clean` clears them.

## The TUI

`devrun up` on a terminal draws a TUI built for three things: read a log, take
lines out of it, and see which process is working.

```
 devrun  athena-new                     3 of 4 running   RAM 3.2 GB   CPU 12.4%
┌─ services ──────────────────────────────────────────────────────────────────┐
│   NAME    STATUS     UPTIME    MEMORY  PROC      CPU RESTARTS      EXIT     │
│ ◉ go      ready      2m 14s    1.3 GB     6 ▁   1.2%        -         -     │
│ ● ui      running    2m 14s    304 MB     4     0.0%        1         -     │
│ ● parser  running    2m 13s    1.6 GB     4 █  99.8%        -         -     │
│ ✗ worker  failed         12s        -     -        -        3    killed     │
│  memory  1.3 GB across 6 processes   firecracker 874 MB   go 58 MB …        │
├─ ▸ go  .devrun/logs/latest/go.log ──────────────────────────────────────────┤
│  {"time":"09:31:33","level":"info","msg":"migrations up to date"}           │
│▌ {"time":"09:31:33","level":"warn","msg":"embedding provider not set"}      │
│▸ {"time":"09:31:33","level":"info","msg":"storage connected"}               │
└─────────────────────────────────────────────────────────────────────────────┘
 ↑↓ line · v select · y copy              ↑↓ Line  v Select  y Copy  ← Back  …
```

| Key | Does |
|---|---|
| `↑` / `↓` | another service in the list, another line in a log |
| `→` / `←` | go into the log, come back to the list |
| click, Tab, `n` / `p` | switch process from anywhere |
| `y` | copy the line you are on, or the lines you picked |
| `v` then `↑` / `↓`, or drag | pick a range of lines |
| Esc | let the picked lines go; again to leave the log |
| wheel, `j` / `k`, PgUp / PgDn | move through the log |
| Home / End, `g` / `G` | jump to the start, or back to live |
| `s` / `r` / `S` | stop, restart, start this process |
| `?` | every key, spelled out |
| `q` | shut the Session down; again to leave immediately |

- **Copy goes over OSC 52**, so it lands on the clipboard of the machine you sit
  at, through SSH and tmux. It takes whole lines, never borders. Your terminal's
  own selection needs **Shift** held, because the mouse is tracked.
- **The box title is the log's path**, so "can you send me this?" is answered by
  a filename.
- **Memory is the whole process tree, as PSS**, not just the process you
  launched. A service started through `uv`, `npm` or a shell wrapper puts almost
  nothing in that first process. `PROC` says how many processes the figure
  covers. The CPU figure includes processes already gone, so a service that forks
  per unit of work (`make`, `tsc`) does not report 0% while pinning a core.
- **State is shown three ways**, as a shape, a word and a colour, so it reads in
  a mono terminal and for readers who cannot separate two colours.
- Piped or redirected, `up` prints prefixed lines instead (`devrun up | tee
  build.log`, CI).

## CLI reference

<details>
<summary><b>Every command</b></summary>

```console
$ devrun up [NAME...] [--detach]   # start everything, or NAME and what it needs
$ devrun up --profile e2e          # the services of [profiles.e2e] and their dependencies
$ devrun up api --no-deps          # only api; a dependency that is off counts as satisfied
$ devrun run CMD...                # supervise one command, no config file
$ devrun down                      # shut a running Session down
$ devrun wait [--timeout D]        # block until everything is ready, or fail
$ devrun logs [NAME...]            # every process's output, merged by time
$ devrun errors                    # what broke, and the log under it
$ devrun status [--json]           # what each process is doing right now
$ devrun samples                   # per-process CPU, memory, disk I/O
$ devrun config [FILE]             # what devrun understood from a config
$ devrun start|stop|restart NAME   # act on one process of a running Session
$ devrun clean [--all]             # delete saved logs from previous runs
$ devrun init [-o FILE]            # write the agent instructions into AGENTS.md
$ devrun skill [print]             # print the agent skill (SKILL.md)
$ devrun skill install [--to DIR] [--refresh]
$ devrun skill uninstall [--to DIR]
$ devrun update                    # replace this binary with the latest release
$ devrun version
```

| `logs` and `errors` options | |
|---|---|
| `--since D` | Only what was written in the last D (`30s`, `2m`, `1h`, `1d`) |
| `--tail N` | Only the last N lines (default 100, 1000 with `--since`) |
| `--all` | No line limit |
| `--grep P` | Keep lines containing any of P, `\|`-separated |
| `-i` | Make `--grep` case-insensitive |
| `--json` | One ndjson object per line: `{"ts","w","msg"}` |
| `--raw` | Byte for byte: keep ANSI, collapse nothing, clip nothing |
| `--no-time` | Drop the leading timestamp |
| `--max-line N` | Clip a line past N bytes (default 1200, `0` to disable) |
| `--path` | Print the log files' paths instead of their contents |

| `run` options (before the command) | |
|---|---|
| `--name NAME` | What to call it (default: the program's name) |
| `--cwd DIR` | Working directory |
| `--restart POLICY` | `no`, `always`, `on-failure`, `exit-on-failure`, `exit-on-end` (default `no`) |
| `--ready-log TEXT` | Count it ready once this appears in its output |
| `--shell` | Let the shell split the words: `--shell 'a; b'` |

Use `--` first if the command's own name starts with a dash.

| Other options | |
|---|---|
| `-f FILE` | Config to read (default `devrun.toml`) |
| `--plain` | Never draw the TUI, even on a terminal |
| `--detach`, `-d` | Run the Session in the background; return once every process is ready |
| `--timeout D` | How long `wait` and `up --detach` give it (default 2m) |
| `--keep N` | Log directories to keep from previous runs (default 10, `0` keeps all) |
| `--window-bytes N` | In-memory log cache across all processes (default 1M; accepts K/M/G) |
| `--profile P`, `--no-deps` | See `up` above |
| `--to DIR`, `--refresh` | For `skill install` / `skill uninstall` |

Run `devrun` with no arguments for the same list in your terminal.

</details>

## FAQ

**Why is there no MCP server?**
Every coding agent already has a shell, and `devrun logs --since 2m --grep error`
is one call. An MCP server would be a protocol, a process and a schema to keep in
sync to offer the same thing. If that turns out to be wrong it is a small thing to
add later.

**Does it work on macOS?**
Not yet. Nothing is built that would have to be torn out to add it: the event loop
is `poll()` with a self-pipe, and resource accounting sits behind one narrow
backend interface. [ADR 0004](docs/adr/0004-portability-posture.md) covers what a
port costs.

**Does it leave anything behind?**
One directory, `.devrun/`, beside your config: the log files, the control socket,
and a detached Session's own output. No daemon, no runtime, no second config file.

**What if my logs are enormous?**
The log files on disk keep everything, byte for byte. The in-memory window is 1 MB
across all processes by default (`--window-bytes` to change it), and scrolling
past it reads the file with `pread`. RSS does not follow log volume.

**Migrating from 0.1?**
0.2.0 reads `devrun.toml` and no longer reads the old YAML config. The move is
mechanical, and `devrun config` names the devrun field for every old one it meets.
The field-by-field map is under "Breaking: devrun has its own config" in the
[CHANGELOG](CHANGELOG.md).

## Design decisions

The non-obvious choices are written down with the reasoning that produced them:

- [Logs travel through the filesystem, not through the control socket](docs/adr/0001-logs-through-the-filesystem.md)
- [Zig, not Rust](docs/adr/0003-zig-over-rust.md)
- [Portability posture: portable by construction, Linux-only by scope](docs/adr/0004-portability-posture.md)
- [Render log bytes straight through, rather than through a cell grid](docs/adr/0005-render-log-bytes-through.md)
- [Every Session gets its own directory of Archives](docs/adr/0006-an-archive-per-session.md)
- [Time lives beside the bytes, in a sidecar, not inside the Archive](docs/adr/0007-time-beside-the-bytes.md)
- [devrun reads its own devrun.toml, and nothing else](docs/adr/0008-devrun-toml.md)

[`CONTEXT.md`](CONTEXT.md) is the glossary (Worker, Group, Gate, Archive, Window).
[`CHANGELOG.md`](CHANGELOG.md) says what changed for someone using devrun. Not
done, deliberately: log search in the TUI, `liveness_probe`, and the reserved
config fields `include` and `ready.tcp`.

## Credits

- **[mandor](https://github.com/asyafalni/mandor)** by Alfin Syafalni. A PID-1 container supervisor in Zig. Different shape, same problems; read closely, and borrowed from per-function with attribution.

## License

MIT. See [LICENSE](LICENSE).
