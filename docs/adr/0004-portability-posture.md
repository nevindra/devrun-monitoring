# Portability posture: portable by construction, Linux-only by scope

macOS is out of scope for v1, but nothing is built that would have to be torn out to add it. Two rules carry that: the event loop uses `poll()` with a self-pipe for signals rather than `epoll` with `signalfd`, and everything touching the OS for resource accounting sits behind one narrow backend interface.

At roughly twelve file descriptors, `poll()` is indistinguishable from `epoll` in cost, and it is POSIX — so the core loop needs no second implementation. `signalfd` would have forced a `kqueue` port of exactly the code that is hardest to get right. Choosing the portable primitive costs nothing today and removes most of the work a macOS port would otherwise involve.

## Consequences

- A macOS port is roughly one file: `sysctl(KERN_PROC_PGRP)` in place of scanning `/proc` for a pgid, and `proc_pid_rusage` / `proc_pidinfo` in place of reading `/proc/<pid>/{stat,io,smaps_rollup}`. The loop, the accumulation, and the delta handling are shared.
- Zig bundles `libproc.h`, `sys/proc_info.h`, and a `libSystem` stub, so that build cross-compiles from Linux without an Apple SDK. It still has to be tested on real hardware.
- macOS would lose PSS (RSS only), lose cgroup-exact CPU, and has no `PR_SET_CHILD_SUBREAPER` — orphaned grandchildren escape to launchd, with no remedy beyond killing the Group.
- On Linux, cgroup v2 supplies CPU, memory, and process count, but the `io` controller is not delegated to user sessions, so disk I/O is summed per-pid from `/proc/<pid>/io`. That per-pid summing path is the same shape macOS needs — so it is not a workaround for a missing controller, it is the portable path, and it was required anyway.
- Because CPU comes from the cgroup on Linux but would be summed per-pid on macOS, the per-pid delta accumulator that disk I/O already needs must be written to serve CPU too. A pid that exits takes its cumulative counters with it; without accumulation the totals go backwards and rates go negative.

## Amendment: CPU is read per-pid, and no longer through the accumulator

Two things above did not survive contact with the implementation.

CPU is read per-pid on Linux as well, not from the cgroup. Keeping two backends for one number — cgroup here, `proc_pid_rusage` there — meant maintaining the harder of the two for no reading a user could tell apart, so the path that disk I/O forced anyway is the path CPU takes too.

And the delta accumulator turned out to be the wrong instrument for CPU. It banks what a pid reported *while it was observed*, so a pid that was never observed contributes nothing — and a Worker that forks per unit of work (`make`, `tsc`, a test runner) has almost every child born and reaped between two 1 Hz ticks. Such a Worker reported 0% while pinning a core, which is not a rounding error but the reading being wrong about the thing most worth knowing.

`cutime`/`cstime` in `/proc/<pid>/stat` already hold the CPU of reaped children, recursively. Because a live pid is in nobody's `cutime`, summing `utime + stime + cutime + cstime` over the live set counts every tick exactly once and needs no accumulator to survive a pid vanishing — it is also race-free across a reap, which sampling faster would not have been. Disk I/O has no such field and keeps the accumulator.

This is the one place the two platforms now diverge in shape rather than only in syscall. macOS has no per-process view of reaped descendants to match `cutime`; a port would have to reach the same total another way, most likely by capturing `rusage` at `wait4` time and attributing it by Group. That is unresolved, and worth knowing before the port rather than during it.

## Amendment: memory is PSS, read on a rotation

Memory does not come from the cgroup either, for the same reason CPU does not. It is summed per-pid, which raises a question RSS gets wrong: **a sum over processes has to use PSS.**

RSS counts a shared page once in every process mapping it. A Worker that forks shares nearly all of its pages with its children until they are written, so summing RSS counts the same memory several times over — measured on a parent holding 300 MB with three forked children, the sum of RSS was 1300 MB against 325 MB of PSS, a factor of four. Against a real Session it was less dramatic and more misleading: a Python service reported 1.9 GB of summed RSS where the machine had given it 1.6 GB. PSS divides each page among the processes mapping it, which makes the figures additive by construction — the property a per-Group total needs and the only reason to prefer it.

The cost is why the implementation had drifted to RSS in the first place. `/proc/<pid>/stat` is answered from counters the kernel already keeps; `smaps_rollup` makes it walk the page tables. Over a fifteen-process Session that is 51 µs against 19.9 ms — 390×, scaling with a process's mappings rather than with how many processes there are. Paying it for every pid every second would have made accounting the largest thing devrun does.

So PSS is read for a few pids per tick, stalest first, while CPU stays on `stat` for every pid every tick. The asymmetry is not a compromise but a match to the signals: memory moves slowly enough that a few seconds of lag cannot mislead, and CPU does not. A pid whose turn has not come reports its RSS, so a Group's figure begins where it always did and settles downward onto the truth — it never begins at zero, which is the one answer a reader would take as fact rather than as a figure still arriving.

This restores what the consequences above already assumed: `smaps_rollup` in the read set, and PSS as the thing a macOS port would be giving up.

## Amendment: macOS is in scope, and the port was the size predicted

The posture paid off as stated. The event loop, the self-pipe, the Group, the accumulator and the rotation are unchanged; what changed sits behind the seams this ADR drew. Four things are worth knowing that the paragraphs above did not say.

**The syscall layer goes through libc on macOS, and only there.** macOS has no stable syscall ABI, so `os.zig` reaches libSystem through `std.c` behind a shim that returns results in the Linux kernel's convention — a value, or a negated errno — and everything above it is written once. Linux keeps calling the kernel directly and stays a static ELF. Signals are the enum, never a number: SIGUSR1 is 10 on one platform and 30 on the other.

**The CPU question left unresolved above has an answer, and it is the same rule.** `proc_pid_rusage` with `RUSAGE_INFO_V2` returns `ri_child_user_time` and `ri_child_system_time`, which XNU folds in at reap time, recursively — `cutime` and `cstime` by another name. So `Σ live (own + reaped children)` holds unchanged and nothing had to be captured at `wait4`. One trap: the `*_time` fields are Mach absolute-time units, not the nanoseconds the header claims, and on Apple silicon a unit is 125/3 ns.

**Groups are enumerated, not walked.** With no subreaper there is no subtree to walk, so a tick asks `proc_listpids(PROC_PGRP_ONLY, pgid)` for each Group. That names exactly what `kill(-pgid)` would reach — which also means an orphan that stays in its group is still measured and still killed, so losing the subreaper costs less than the consequences above expected. Memory is `ri_phys_footprint`: not PSS, but cheap and additive in the way that matters, so there is no rotation.

**The file watcher was the part this ADR did not anticipate.** kqueue is not inotify: a directory's vnode says *that* it changed, not *what*, and a file edited in place changes nothing in its directory. So each directory keeps a name-and-inode snapshot that is diffed on change, and each watched file holds an `O_EVTONLY` descriptor of its own, under the same 16384 cap, with the soft descriptor limit raised to fit and restored for each Worker. FSEvents would have avoided the descriptors, but it needs CoreServices, and with it an Apple SDK at link time — the cross-compile from Linux that the release depends on would have been lost.
