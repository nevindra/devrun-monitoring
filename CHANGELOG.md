# Changelog

Newest first. Versions follow [semantic versioning](https://semver.org); until
1.0 a minor bump is where a breaking change is allowed to live.

Entries say what changed for someone *using* devrun. Refactors, test additions
and internal tidying stay in the git log, which is where they are useful.

## Unreleased

devrun now reads out loud as well as it writes. The Archives were always plain
files; what was missing was a way to ask them a question — across every
process at once, over a time window, without spending a context window on the
answer.

### Every process's output, merged by time

- **`devrun logs` prints the logs.** With no arguments: every process,
  interleaved in the order things actually happened, which is the view you
  cannot get by running one dev server in one terminal.
- `--since 30s`, `--tail N`, `--all`, `--grep 'panic|ERROR'`, `-i`, `--json`.
- Merging is backed by a new `.devrun/logs/<name>.idx` sidecar recording when
  each chunk of output was written. The Archive is untouched and still
  byte-faithful — see [ADR 0006](docs/adr/0006-time-beside-the-bytes.md) for
  why time lives beside the bytes rather than in them.
- **Breaking:** `devrun logs NAME` used to print the Archive's path. That is
  now `devrun logs NAME --path`.

### Output that costs less to read

The default view drops what only a terminal was ever going to act on. On a
realistic dev workload — a Vite reload loop, a rebuild loop, 50 request log
lines, a progress bar, and one minified bundle line — the four log files came
to **153 lines and 19,880 bytes**; `devrun logs --all` renders the same content
in **6 lines and 1,447 bytes**.

- ANSI escapes stripped (`--raw` keeps them).
- A progress bar that rewrote itself in place shows its final state, not every
  frame it drew.
- Consecutive identical lines fold into one plus a count: `rebuilding… ×40`.
- A single line past 1200 bytes is clipped with the byte count that was cut
  (`--max-line N`, or `0` for no limit).
- Bounded to the last 100 lines by default, 1000 with `--since`.
- Nothing is dropped silently: a note on stderr says how much was folded,
  clipped, or left behind, and `--raw --all` puts all of it back.

### One command, no config file

**`devrun run pnpm dev`** supervises a single ad-hoc command. No
`process-compose.yaml` required, which means devrun now does something in a
repo that does not have one. Works with anything you can type in a shell:
`devrun run go run ./cmd/api`, `devrun run bun run dev`, `devrun run cargo watch`.

- Everything else follows from it: the Archive, the Index, and therefore
  `devrun logs`, `errors`, `status`, `wait` and `--detach`.
- Exits with the command's own exit status, including `128 + signal` when it
  is killed, so it works as a wrapper in a script or a Makefile.
- `--name`, `--cwd`, `--restart POLICY`, `--ready-log TEXT`.
- The command's words are passed through untouched. `devrun run pnpm dev --json`
  gives `--json` to pnpm, not to devrun, and devrun's own flags go before the
  command. Each word is quoted for the shell, so `devrun run node -e "f('a b')"`
  arrives as one argument rather than being split a second time. `--shell`
  turns that off for `devrun run --shell 'sleep 1; echo hi'`.
- One Worker gets no name column and no state commentary, so `devrun run`
  looks like running the command directly.

`devrun logs` now finds its processes from the config, or from a running
Session, or from the log directory, in that order. That is what lets it work
against an ad-hoc run both while it is going and after it has finished.

### Commands for callers that are not people

- **`devrun up --detach`** runs the Session in the background and returns once
  every process is ready, non-zero if one fails. A process with a readiness
  probe is not counted ready until the probe says so.
- **`devrun wait [--timeout D]`** blocks on an already-running Session.
- **`devrun down`** shuts one down through the same ladder `q` uses.
- **`devrun errors`** answers "did anything break" in one call: what is broken,
  its exit code, the tail of its log, and any error-shaped lines from processes
  that are still up. Exits non-zero while anything is broken.
- **`devrun status`** is now one aligned line per process instead of raw
  columns, and `--json` gives one object per process with a `broken` flag.
  The socket's own reply gained exit-code, uptime, and readiness columns. The
  last one is what lets `wait` tell "running, and that is all it will ever be"
  from "running, probe has not passed yet" without reading the config.
- **`devrun init`** writes a short devrun section into `AGENTS.md` (or
  `CLAUDE.md`, whichever the repo has), between markers so it can be re-run.
- An unrecognised `--flag` is now an error rather than being read as a process
  name, matching how the config loader treats fields it does not understand.

## 0.1.0

First release. Everything in the original plan is in it.

### Runs the processes

- Reads an existing `process-compose.yaml` — no second config file. A strict
  subset of the schema, and **any field outside it is refused rather than
  ignored**, so two people running the same file cannot get different
  behaviour with nothing on screen to say why.
- `${VAR}` and `$VAR` expand over the raw file before YAML parsing, `.env`
  taking precedence over the OS environment — matching process-compose.
  `${VAR:-default}` is rejected, as it is there.
- Dependency graph with all five `depends_on` conditions, the four
  `availability.restart` policies, and a shutdown ladder honouring the signal
  and grace period the file asks for.
- Readiness probes over `exec` and `http_get`, plus `ready_log_line`.
- A config whose graph could never resolve — a `depends_on` cycle, a
  `process_healthy` wait on a process with no probe — is refused at load
  rather than hanging the Session later.
- `devrun config` prints what devrun understood from a file, which is worth
  running on its own.

### Keeps the logs

- Every process writes to `.devrun/logs/<name>.log` from the moment it spawns:
  a plain file, byte-faithful, ANSI intact, readable with `tail -f`, `grep`,
  `less` and your editor while the Session runs.
- The in-memory Window is a bounded cache (1 MB across all Workers, `--window-bytes`
  to change it), not the record. Scrolling past it reads the file with `pread`,
  so scrollback reaches the start of the run rather than the end of a buffer.
- `devrun logs NAME` prints the path, and hands you off to the tools that
  already read files better than devrun would.

### Shows what is happening

- A TUI over those files: log pane at full width, drag or `v` to pick lines,
  `y` to copy over OSC 52 — so it lands on the clipboard of the machine you
  are sitting at, through SSH and tmux. Excerpts go out as plain text.
- Per-Worker CPU, memory and disk I/O across the whole process tree. CPU is
  read per-pid and counts children already reaped, so a Worker that forks per
  unit of work no longer reports 0% while pinning a core. Memory is PSS on a
  rotation rather than summed RSS, which counted shared pages once per process.
- Every state is said three ways — a shape, a word, and a colour — so the view
  survives a mono terminal, a screenshot, and a reader who cannot separate two
  of the colours.
- Piped or redirected, `devrun up` prints prefixed lines instead of drawing.

### Control socket

- `devrun status`, `samples`, `start`, `stop` and `restart` over
  `.devrun/control.sock`. Logs never cross it, which is what keeps it a
  trivial line protocol.
- A second Session in the same directory is refused rather than left to
  truncate the first one's Archives.

### Install

- Static x86_64 and aarch64 binaries, published on tag by the release
  workflow and checksummed against the release's `SHA256SUMS`.
- `curl -fsSL …/install.sh | sh` installs into `~/.local/bin`, or wherever
  `DEVRUN_INSTALL_DIR` points.
- `devrun update` runs that same script rather than reimplementing it, and
  replaces whichever binary was invoked — a source build and an installed
  release do not overwrite each other.
- `devrun version` prints the version and nothing else.
