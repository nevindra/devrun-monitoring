# Every Session gets its own directory of Archives

`.devrun/logs` holds one directory per Session, named for the moment it started — `2026-08-14T10-32-05Z` — with a `latest` symlink aimed at the newest. A Session never writes to a path a previous Session wrote to.

Before this, every Session opened `.devrun/logs/<name>.log` with `O_TRUNC`. That made an absolute byte offset the same thing as a file offset, which is what lets the TUI scroll by `pread` with no index — but it also meant the way you reproduce a bug destroyed the evidence of it. Restarting to try something is the most common thing anybody does with a process runner, and the log you wanted was always the one from the run before.

Keeping history needs a name that is not reused, and a name that is not reused cannot be the name anybody types. So there are two names: the stamp, which is unique, and `latest`, which is stable. `devrun logs api`, the log pane's title, and the README all quote the stable one.

The alternatives were worse in ways that showed up immediately. Appending to one file per Worker forever breaks the offset-is-file-offset invariant the whole viewer rests on, and leaves no boundary to delete on. A `.1`, `.2` rotation makes "the log from the run where the migration failed" a counting exercise, and renames files somebody may already have open in an editor.

## Consequences

- Disk use now grows with the number of runs, so something has to forget. `devrun up` keeps the newest ten Sessions and says how many it deleted; `--keep N` changes that, and `--keep 0` keeps everything.
- Quitting the TUI offers to delete saved logs — all of them, or every run but the one that just finished. The offer is made after shutdown rather than on the first `q`, so the `q q` that is already muscle memory cannot answer it by accident.
- `devrun clean` does the same thing for anyone who leaves by Ctrl-C or never sees a TUI. It refuses `--all` while a Session is running, because deleting the Archives a live Session is writing leaves it appending to files no path reaches.
- Only a directory whose name is exactly a stamp is ever deleted. A file somebody parked in `.devrun/logs` is not something this code can reach, which is the property worth having in code whose job is to delete things.
- Two Sessions starting inside the same second in the same directory share a directory and truncate each other, exactly as every pair of Sessions used to. `control.sock` already prevents the overlapping case, so what is left is a one-second window that costs less to accept than a suffix scheme would cost to recognise everywhere a delete happens.
