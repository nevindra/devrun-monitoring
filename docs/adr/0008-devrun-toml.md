# devrun reads its own devrun.toml, and nothing else

Supersedes [0002](0002-read-process-compose-yaml.md).

devrun reads `devrun.toml`, with a schema of its own. It no longer reads `process-compose.yaml` at all, not even as a fallback.

0002 bought coexistence with process-compose at the price of its schema, and the schema turned out to be most of what made devrun awkward to write a config for. `availability: { restart: on_failure }` for one setting, `depends_on: { db: { condition: process_completed_successfully } }` for one edge, five dependency conditions of which two meant "ready", and YAML on top: `restart: no` reading as a boolean, indentation errors, and `${VAR}` substituted into the raw text before parsing so that a value with a colon could reshape the document. A fallback reader would have kept all of that alive as a second parser to maintain and a second set of rules to explain. A one-time converter was considered and dropped for the same reason: it is still the old schema, living in the codebase.

## Why TOML

Not because it can express more than YAML. For a process runner it expresses the same things, and the format was stress-tested against sixteen shapes of config, from one service to a forty-service monorepo with profiles, replicas and per-package files, before choosing. What TOML removes is the class of mistake that has nothing to do with what the user meant: no significant indentation, no implicit typing of `no` or `on`, and strings are always quoted. JSON was out because a config without comments is worse to live with than any of this.

The one shape TOML handles badly is a list of objects with objects inside them (`[[a.b]]` followed by `[a.b.c]`). The schema is designed so that never comes up, by the first rule below.

## The rules the schema follows

1. **Everything with an identity is a table keyed by name, never a list.** Services, templates and profiles. This is what keeps the file flat at any size: `[services.api]` is greppable, and a forty-service file is forty short sections rather than one deep tree.
2. **Every field has a short form and, where it needs one, a long form.** `after = ["db"]` or `after = { db = "succeeded" }`. `ready = "http://..."` or `[services.api.ready]` with timing. `run = "..."` or `run = ["docker", "run", ...]`. A small config stays three lines per service without capping a large one.
3. **Reuse belongs to the schema, not the format.** `[env]` and `env_file` at the top level reach every service, and `[templates.x]` with `extends = "x"` replaces what YAML anchors were used for, more legibly.
4. **A step complex enough to need its own `cwd`, `env` or timeout is a service.** That is what a Gate already is, and it is why hooks, when they come, can be arrays of strings rather than arrays of tables.
5. **Unknown fields are refused, never ignored.** Kept from 0002, for a different reason: a typo in a field name must not produce a service that silently behaves differently. Names reserved for later are refused with a message saying they are coming, so adding them later cannot change what an accepted file means. That was the case for `profiles`, `replicas`, `watch` and `restart` as a table, which are now implemented without changing any file that was accepted before. Still reserved: `include` and `ready.tcp`. Familiar names from other runners (`command`, `depends_on`, `readiness_probe`) are refused with the devrun name.

## Variables

`${VAR}`, `$VAR` and `${VAR:-default}` expand per value, after parsing, and only in fields the shell never sees: `env`, `env_file`, `cwd` and `ready.http`. `run` and `ready.exec` reach the shell untouched, with the Worker's environment to expand them from, so `awk '{print $NF}'` means what it says. Lookups go top-level `env`, then top-level `env_file`, then the environment devrun started in, which is the same order a Worker's environment is layered in.

## One ready check, one meaning of "ready"

process-compose had `process_healthy` for a probe and `process_log_ready` for a line in the output. To someone writing the file they are the same question. `ready` is now one block holding exactly one of `http`, `exec` or `log`, and `after = { x = "ready" }` means whichever one `x` has. The short form `after = ["x"]` waits for `ready` when `x` has a check and `started` when it does not.

## Replicas expand at build time

`replicas = N` is expanded when the config is built, into N ordinary services named `<name>.1` to `<name>.N`. Each gets `DEVRUN_REPLICA=<k>`, and `${DEVRUN_REPLICA}` is substituted in `env`, `env_file`, `cwd` and `ready.http` along with every other variable. That is the reason for expanding early: the per-replica port in `ready = "http://127.0.0.1:300${DEVRUN_REPLICA}/health"` has to be a different string for each instance, and variables are resolved per value after parsing. Expanding later, in the supervisor, would have meant a second notion of "a Worker" that is one entry in the config and several at run time. Instead the rest of devrun sees plain Workers, each with its own Archive, and only the CLI and `after` know that `worker` can mean all of them.

## Local overrides

`devrun.local.toml` beside `devrun.toml` (`x.local.toml` beside `x.toml` for `-f`) is merged over it when present: tables merge key by key, anything else replaces. It exists for what is true of one machine, a port that clashes or a token, and should not be committed. `devrun config` says when it merged one.

## Consequences

- Every existing `process-compose.yaml` stops working and has to be rewritten. The mapping is mechanical and the error messages name the devrun field for each old one, but it is a breaking change for anyone on 0.1.
- A teammate on process-compose can no longer share the file. That was the point of 0002, and it is given up deliberately.
- The vendored zig-yaml and its local patch are gone. The TOML reader is ours, about 700 lines, and implements TOML 1.0 except dates and times, which no field uses. Inline tables are held to one line, the 1.0 rule, so that an editor still on 1.0 never shows red on a file devrun accepts.
- The binary grew by about 70 KB. The reader is smaller than zig-yaml was; the growth is the mapping and its error messages, which ReleaseFast inlines generously. Worth revisiting if the size starts to matter.
