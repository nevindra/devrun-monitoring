# Changelog

Newest first. Versions follow [semantic versioning](https://semver.org); until
1.0 a minor bump is where a breaking change is allowed to live.

Entries say what changed for someone *using* devrun. Refactors, test additions
and internal tidying stay in the git log, which is where they are useful.

## Unreleased

### The arrow keys mean what they look like

- **`↑` `↓` act on whatever you are in, `→` goes in and `←` comes back out.**
  In the service list the arrows walk services; in a log they walk lines. They
  used to be half of one model and half of another — `↑` `↓` scrolled the log
  while `←` `→` switched service — so neither reading was right.
- **`v` starts a selection at the line you are on**, not at the top of the
  screen. Picking a stack trace out of a busy log no longer means scrolling
  until the line you want happens to be the first one.
- **`y` with nothing selected copies the line you are on** when you are inside
  a log; from the service list it still copies the screenful on show.
- A single click in the log moves the cursor instead of starting a one-line
  selection, so a stray click cannot leave a selection behind for the next `y`
  to copy.
- The footer now changes with where you are, and names the arrow keys. What you
  can do is on screen rather than behind `?`.

### Logs survive a restart

- **Every run writes to its own directory** — `.devrun/logs/<timestamp>/` — with
  `.devrun/logs/latest` pointing at the newest. Restarting to reproduce a bug no
  longer deletes the log of the run you were reproducing.
- `devrun logs api` and the log pane's title now quote
  `.devrun/logs/latest/api.log`, which stays true tomorrow.
- `devrun up` keeps the newest **10** runs and says how many it deleted.
  `--keep N` changes that; `--keep 0` keeps every one of them.
- **Quitting offers to delete saved logs** — `y` for all of them, `o` for every
  run but the one that just finished, Enter to keep. The offer comes after
  shutdown, so a habitual `q q` still leaves without deleting anything.
- **`devrun clean`** does the same from a shell, for anyone who leaves by
  Ctrl-C. `--all` includes the newest run, and is refused while a Session is
  running.

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
