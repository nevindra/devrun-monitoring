# devrun

A process runner for local development: it starts the services a repo needs, shows their logs, and — the reason it exists — lets you get those logs back out. It reads a `devrun.yml`.

## Language

### Processes

**Worker**:
One entry under `services:` in the config. A single Worker usually becomes several OS processes.
_Avoid_: process, service, job, task

The config file and everything a user reads say **service**, not Worker. That split is deliberate: "worker" already means a background job consumer in most stacks, and a `workers:` block containing a service named `worker` reads badly. Worker is the name inside the code, and the _Avoid_ list above applies there in full. See `docs/adr/0008-devrun-yml.md`.

**Group**:
Every OS process sharing a Worker's process group id. This is the unit that gets measured and the unit that gets killed — never the single pid that was spawned.
_Avoid_: tree, children, descendants, brood

**Gate**:
A Worker that is expected to exit. Its successful exit is what other Workers wait on, so a Gate that never finishes stalls the graph rather than failing it.
_Avoid_: one-shot, init task, hook, pre-start

**Ready**:
The state a readiness probe confirms. Distinct from started — a Worker that bound its port is started; one whose probe passed is Ready.
_Avoid_: healthy, up, alive, live

### Logs

**Archive**:
A Worker's log file on disk, written from the moment it spawns. The source of truth, kept byte-faithful with its ANSI intact.
_Avoid_: log file, sink, output, dump

**Window**:
The slice of an Archive held in memory, bounded in bytes rather than lines. A cache of the Archive, never the record itself.
_Avoid_: buffer, scrollback, tail, ring

**Index**:
The `.idx` sidecar beside an Archive: when each chunk of output was written. Everything an Archive cannot say, because saying it would stop the Archive being byte-faithful.
_Avoid_: timestamps file, metadata, journal, offsets

**Chunk**:
One read off a Worker's pipe, and the unit an Index stamps. Every line in a chunk shares its time.
_Avoid_: batch, block, record, frame

**Excerpt**:
What one copy operation produces. Its shape is decided by the view it was taken from, not by a setting.
_Avoid_: selection, clipboard contents, yank, snippet

### The view

**Focus**:
Which of the two places in the view the arrow keys are speaking to — the Worker list or the log. The one thing that decides what ↑↓ mean.
_Avoid_: pane, active panel, mode, tab

**Cursor**:
The line in the log the reader is pointing at. Exists whenever Focus is the log, and is where an Excerpt starts. Distinct from the top of the pane, which is only where the view happens to be scrolled to.
_Avoid_: selected line, current line, caret, highlight

### Observation

**Sample**:
One reading of a Group's resource use at one instant. Cheap enough to take on a timer, never taken per frame.
_Avoid_: metric, datapoint, stat, measurement

### Runtime

**Session**:
One run of `devrun up`. The boundary that rotates Archives, and the lifetime that owns every Group.
_Avoid_: run, instance, invocation, launch
