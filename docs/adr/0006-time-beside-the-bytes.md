# Time lives beside the bytes, in a sidecar, not inside the Archive

Each Worker gets a second file next to its Archive: `.devrun/logs/<name>.idx`, holding fixed-width `(wall_ms, byte_offset)` records, one per chunk read off the Worker's pipe. `devrun logs` binary-searches it to answer `--since`, and to interleave several Archives into one stream ordered by time.

The Archive itself does not change. It stays byte-faithful with its ANSI intact, which is what ADR 0001 bought and what `tail -f`, `grep` and a pager all depend on. The moment a timestamp is interleaved into that file it is no longer what the Worker said, and every tool pointed at it is reading devrun's output rather than the service's.

So the requirement was two things at once: a log that is byte-for-byte the Worker's, and a way to ask when a given byte was written. A sidecar is the only shape that gives both.

## Why per chunk rather than per line

A chunk is one `read()` off the pipe. Every line inside it shares that chunk's stamp.

Per line would cost an index entry for every line — for a Worker writing 80 KB/s of JSON in ~100-byte lines, that is 800 records a second, 12 KB/s of index against 80 KB/s of log. Per chunk, the same Worker costs 16 bytes a second, and usually less: a chunk landing in the same millisecond as its predecessor writes no record at all.

The resolution given up is finer than the question anyone asks. A chunk is one burst of output, so its stamp is the burst's. "What did every service say while that request was failing" is answered exactly. "Which of these two adjacent lines was written first" is not, and never comes up — they are in the file in the order they were written, which is the real answer.

## Why fixed-width and sorted

Both lookups are a binary search of `pread`s: offset-for-a-time to start a `--since`, and time-for-an-offset to put a clock on a printed line. `devrun logs --since 2m` over a 400 MB Archive reads a few hundred bytes and never scans.

That is the whole reason the format has no framing, no compression, and no text. A variable-width or line-oriented index would have to be walked.

## Consequences

- An Archive with no sidecar still works. `IndexReader` treats missing, foreign, or truncated files as empty, and a Worker with no Index appears in merged output with no timestamp, sorted after everything that has one. Losing a Worker's *position* is a small failure; dropping its output would be a large one.
- The sidecar is truncated per Session, exactly like the Archive, because last run's offsets describe nothing in this one.
- Wall-clock time, not `CLOCK_MONOTONIC`. Every deadline in devrun is monotonic and should stay that way, but a stamp is a label read by a *different process* started at a different time, and a monotonic reading cannot be printed or compared across a reboot. A clock that steps mislabels a few lines; a monotonic stamp cannot be read at all.
- `--since` rounds outwards at the front, including the chunk that straddles the cutoff, so the first lines shown may slightly predate the request. Clipping the line that explains the failure is the worse error. The exception is the final chunk: it has no successor to straddle the cutoff with, so if it is older than the cutoff, nothing qualifies — otherwise a Worker that went quiet an hour ago would answer every `--since 30s` with its last words forever.
