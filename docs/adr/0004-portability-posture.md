# Portability posture: portable by construction, Linux-only by scope

macOS is out of scope for v1, but nothing is built that would have to be torn out to add it. Two rules carry that: the event loop uses `poll()` with a self-pipe for signals rather than `epoll` with `signalfd`, and everything touching the OS for resource accounting sits behind one narrow backend interface.

At roughly twelve file descriptors, `poll()` is indistinguishable from `epoll` in cost, and it is POSIX — so the core loop needs no second implementation. `signalfd` would have forced a `kqueue` port of exactly the code that is hardest to get right. Choosing the portable primitive costs nothing today and removes most of the work a macOS port would otherwise involve.

## Consequences

- A macOS port is roughly one file: `sysctl(KERN_PROC_PGRP)` in place of scanning `/proc` for a pgid, and `proc_pid_rusage` / `proc_pidinfo` in place of reading `/proc/<pid>/{stat,io,smaps_rollup}`. The loop, the accumulation, and the delta handling are shared.
- Zig bundles `libproc.h`, `sys/proc_info.h`, and a `libSystem` stub, so that build cross-compiles from Linux without an Apple SDK. It still has to be tested on real hardware.
- macOS would lose PSS (RSS only), lose cgroup-exact CPU, and has no `PR_SET_CHILD_SUBREAPER` — orphaned grandchildren escape to launchd, with no remedy beyond killing the Group.
- On Linux, cgroup v2 supplies CPU, memory, and process count, but the `io` controller is not delegated to user sessions, so disk I/O is summed per-pid from `/proc/<pid>/io`. That per-pid summing path is the same shape macOS needs — so it is not a workaround for a missing controller, it is the portable path, and it was required anyway.
- Because CPU comes from the cgroup on Linux but would be summed per-pid on macOS, the per-pid delta accumulator that disk I/O already needs must be written to serve CPU too. A pid that exits takes its cumulative counters with it; without accumulation the totals go backwards and rates go negative.
