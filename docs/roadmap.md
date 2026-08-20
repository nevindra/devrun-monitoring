# Roadmap: the macOS port

Not started. This is the plan and, more usefully, the trap that is waiting at
the start of it.

[ADR 0004](adr/0004-portability-posture.md) holds the *decisions* that shaped
the codebase for this port and what the port gives up. This file holds the
*work*: what to do, in what order, and what to check before believing any of it.

## The short version

Roughly **6-8 days** for someone who knows this codebase. Nothing in it is
intellectually hard except one problem in `sample.zig`, which is unsolved and
described below.

The difficulty is not volume. It is that **the toolchain will not help you.**
Every wrong step compiles.

## The trap: the build already succeeds, and lies

This works today:

```console
$ zig build -Dtarget=aarch64-macos
$ file zig-out/bin/devrun
Mach-O 64-bit arm64 executable, flags:<NOUNDEFS|DYLDLINK|TWOLEVEL|PIE|...>
```

666 KB, valid Mach-O, linked against `/usr/lib/libSystem.B.dylib`. It looks
finished. Scan the instructions:

| | count |
|---|---|
| `svc #0` — Linux aarch64 syscall convention | **354** |
| `svc #0x80` — Darwin aarch64 syscall convention | **0** |

Every syscall in that binary uses the Linux convention with Linux syscall
numbers. On macOS it is not approximately right, it is wrong in all 354 places.
Zero diagnostics were produced.

The cause is `src/os.zig:23`:

```zig
pub const linux = std.os.linux;
```

`std.os.linux` compiles for any target. It is a namespace of constants and
inline-asm syscall wrappers, not something gated on the host OS. Eighty-five
call sites across four files reach the kernel through it, and not one of them
fails to build when the target is Darwin.

**Do not trust a green build at any point in this port.** Until step 0 below is
done, a green build means nothing at all.

To reproduce the instruction scan:

```console
$ python3 -c "
d=open('zig-out/bin/devrun','rb').read()
for n,p in {'linux':b'\x01\x00\x00\xd4','darwin':b'\x01\x10\x00\xd4'}.items():
    print(n, d.count(p))"
```

## Step 0: make the build fail honestly

Half a day, and the highest-value part of the whole port. Do this before
touching a single syscall.

Put a guard at the top of `src/os.zig`:

```zig
comptime {
    if (builtin.os.tag != .linux) @compileError(
        "os.zig has no Darwin path yet. Port the function you need, give it a " ++
            "`switch (builtin.os.tag)`, and narrow this guard. See docs/roadmap.md.",
    );
}
```

Then narrow it as each function grows a Darwin arm. The compiler now maintains
the worklist instead of you, and a green build starts meaning something.

Without this you are porting blind, and every intermediate commit ships a
binary that looks fine and is not.

## The worklist

### Phase 1 — `src/os.zig` (2-3 days, 70 call sites)

43 distinct syscalls are used across the codebase. **37 of them are a rename**
to `std.posix`: read, write, pread, close, lseek, mkdir, rmdir, unlink,
symlink, chdir, getcwd, execve, exit, kill, setpgid, setsid, getpgid, getpid,
dup2, poll, socket, bind, connect, listen, fcntl, getsockopt, sigaction,
sigemptyset, sigprocmask, nanosleep, clock_gettime, faccessat, errno, fork,
wait4, ioctl, openat.

Six need more than a rename:

| site | now | on Darwin |
|---|---|---|
| `os.zig:267` | `pipe2` | no such call — `pipe` + two `fcntl` |
| `os.zig:325` | `accept4` | no such call — `accept` + `fcntl` |
| `os.zig:179` | `statx` | `fstat` |
| `os.zig:394` | `getdents64` + hand-rolled `Dirent64` | different dirent layout; `readdir`/`getdirentries` |
| `os.zig:225` | `readlink("/proc/self/exe")` | `proc_pidpath` (also `update.zig:54`) |
| `os.zig:254` | `linux.O` flag struct | different bit layout — `std.c.O` |

One has **no Darwin equivalent at all**:

- `os.zig:511`, `prctl(PR_SET_CHILD_SUBREAPER)`. macOS has nothing like it.
  Orphaned grandchildren reparent to launchd. The existing mitigation already
  covers most of it — devrun kills by process group, not by pid — so this is a
  degradation rather than a blocker. Anything that calls `setsid` for itself
  escapes, on both platforms.

### Phase 2 — `src/sample.zig` (2-3 days)

The real work, and the only part that needs thinking rather than typing.

ADR 0004 says resource accounting sits behind "one narrow backend interface".
**It does not.** `readStat`, `readIo`, `readPss`, `scanProc` and `pushChildren`
read `/proc` directly. Building that interface is the first task here, not the
port itself.

Touch points: `sample.zig:298` (`pushChildren`), `:327` (`scanProc`), `:497`
(`childrenSupported`), `:543` (`readStat`), `:618` (`readPss`), `:650`
(`readIo`).

Three of the four numbers get *easier* on macOS:

| | Linux now | Darwin |
|---|---|---|
| pids in a group | walk all of `/proc`, then `task/<tid>/children` | `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid)` — one call, replaces both walks |
| CPU | `/proc/<pid>/stat` | `proc_pid_rusage` → `ri_user_time` + `ri_system_time` |
| disk I/O | `/proc/<pid>/io` + accumulator | `proc_pid_rusage` → `ri_diskio_bytes{read,written}`, same accumulator |
| memory | `smaps_rollup` PSS | **no PSS.** Closest is `ri_phys_footprint` |

Losing PSS matters more than it sounds. PSS divides each shared page among the
processes mapping it, which is the property that makes a per-group *sum*
additive. `ri_phys_footprint` does not, so a service that forks will
over-report. Group memory on macOS will read systematically higher than the
same session on Linux. Say so in the UI or the docs rather than letting two
machines disagree silently.

No Apple SDK is needed. `proc_pid_rusage`, `proc_pidpath` and `sysctl` are all
libSystem symbols and Zig ships a `libSystem.tbd` stub, so declaring the externs
and the two `kinfo_proc` fields by hand is both sufficient and safer than
trusting whatever headers Zig bundles. ADR 0004 claims Zig bundles `libproc.h`;
verify that rather than believing it.

### Phase 3 — the small ones (1 day)

- **`src/term.zig`** — three constants at `:20-22` are Linux x86_64 ioctl
  numbers. Darwin wants `TIOCGETA` 0x40487413, `TIOCSETA` 0x80487414,
  `TIOCGWINSZ` 0x40087468. The `termios` struct at `:67` also differs in field
  widths (Darwin uses 64-bit `c_iflag` and friends). Four ioctl call sites.
- **`src/control.zig:25`** — `sockaddr.un` on Darwin carries a leading `len`
  byte and `sun_path` is 104 bytes, not 108. Struct swap. The existing
  `error.NameTooLong` check keeps working and matters slightly more.
- **`src/probe.zig:65`** — `sockaddr.in`, same story.
- **`src/update.zig:99`** — `execve` via `os.linux`; falls out of phase 1.
- **`install.sh:69`** — the `[ "$os" = "Linux" ]` gate, and the tarball name at
  `:134`. Note the comment at `:165` about `mv` over a running binary: that
  holds on macOS too, but confirm it.
- **`.github/workflows/release.yml:51`** — add `aarch64-macos` and
  `x86_64-macos` targets.

### Phase 4 — proving it (unbounded without hardware)

Everything above can be written from Linux. **None of it can be tested from
Linux.** Half of this port is the category "compiles fine, behaves differently",
which is exactly what a cross-compiler cannot catch.

CI needs a `macos-14` runner actually running `zig build test`, not a
cross-compile that produces an untested artifact.

## The one unsolved problem

**CPU for reaped children.** Flagged in the ADR 0004 amendment and still open.

On Linux, `cutime`/`cstime` in `/proc/<pid>/stat` hold the CPU of reaped
descendants, recursively. That is why a `make` or a `tsc` that forks two hundred
short-lived children reads correctly: summing `utime + stime + cutime + cstime`
over the live set counts every tick exactly once, and survives a pid vanishing
between ticks.

macOS has no external per-pid view of reaped descendants. `proc_pid_rusage` sees
only the live process. The options, all bad:

1. **Reinstate the delta accumulator on Darwin.** Returns to the bug that
   motivated removing it: a service forking per unit of work reports 0% while
   pinning a core, because almost every child is born and reaped between two
   1 Hz ticks.
2. **Sample at 10 Hz.** Narrows the window, does not close it, and makes
   accounting the most expensive thing devrun does.
3. **Capture `rusage` at `wait4` time.** Unreachable: devrun reaps only its own
   direct children — the shell. The grandchildren's CPU lands in that shell's
   `RUSAGE_CHILDREN`, which cannot be read from outside the process.

Recommendation: **take option 4, accept it and document it.** CPU on macOS
covers live processes only. The difference is visible on fork-heavy services and
nowhere else. Decide this before the port, not during it.

## Already paid for

Two things do not need doing, both deliberate:

- The event loop is `poll()` with a self-pipe, not `epoll` with `signalfd`.
  Both are POSIX. The hardest code to get right needs no second implementation.
  This was ADR 0004's whole point and it held up.
- Config signals are **names**, not numbers (`signal: SIGINT`). SIGUSR1 is 10 on
  Linux and 30 on macOS, so a config holding `10` would mean two different
  things on two machines while looking identical. See
  [ADR 0008](adr/0008-devrun-yml.md).

## What macOS will not have

- Static linking. libSystem cannot be statically linked; Apple does not support
  it. The binary links the system libc like every other macOS binary. The
  README's "one static binary" line and its badge need to say Linux.
- PSS, per phase 2.
- Exact CPU for fork-heavy services, per above.
- `PR_SET_CHILD_SUBREAPER`, per phase 1.

## Before writing any code

Three things to check on real hardware, because each one can invalidate a phase:

1. Does a cross-compiled `aarch64-macos` binary run at all? Zig's linker
   ad-hoc signs arm64 Mach-O output, which the kernel requires. Confirm it
   rather than assume it.
2. Does `proc_pid_rusage` return what is expected for a child process of the
   caller? Everything in phase 2 rests on it.
3. Does `poll()` behave on the fds devrun actually polls — pipes and a unix
   socket? Darwin's `poll()` has a long history of trouble with devices and
   ptys. Pipes should be fine. Should.
