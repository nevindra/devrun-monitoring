# devrun.yml: our own schema, still in YAML

devrun reads `devrun.yml`, a format it defines, parsed by the YAML parser it already vendors. This reverses [0002](0002-read-process-compose-yaml.md), which read `process-compose.yaml` directly.

## Why the reversal

0002 bought coexistence: one file, two tools, neither aware of the other. That was worth having while devrun was proving it could supervise anything at all. It is not worth what it costs now.

The cost is that every question about the config has two answers. A field devrun wants and process-compose does not have cannot be added. A default worth changing cannot be changed, because matching was the promise. `depends_on` defaults to `process_started` — the pid exists — when what a dev stack almost always means is "the database is accepting connections". Under 0002 that default was not ours to fix.

Coexistence also turned out to be a smaller prize than it looked. The tools do not overlap for long: the person running `devrun up` stops running `process-compose up` within a day, because the whole reason they installed devrun is that they want their logs back out. A compatibility promise nobody exercises is a constraint paid for daily and collected on never.

## Why still YAML, and not TOML

The parser is vendored, working, and its errors carry line and column through `std.zig.ErrorBundle`. `sam701/zig-toml` has a `zig-0.16` branch and would decode straight into structs, deleting most of the mapping layer — but its errors are bare enum values with no position and no field name, and its README marks error handling as unfinished. This module's entire purpose is refusing precisely (see `unsupported` in `src/config.zig`), so trading a whole mapping layer for a whole diagnostic layer is not a trade.

TOML would also have removed two real footguns: indentation, and `${VAR}` substitution running over unquoted text. Neither outweighs the diagnostics today. If zig-toml grows positional errors, this is worth revisiting.

## The shape, and what decided it

- **Top-level key is `services`, not `workers`.** The domain term is Worker (see `CONTEXT.md`) and the code keeps it. The file does not, for two reasons: "worker" already means a background job consumer in most stacks, and a config full of `workers:` containing a service genuinely named `worker` reads badly. The split between the internal name and the file's name is deliberate and recorded in `CONTEXT.md` so it does not later look like drift.
- **A service is a string or a mapping.** Most services in a real repo are one command. `tailwind: pnpm tailwindcss -w` is the whole entry. The two forms are different YAML types rather than two shapes of one, so nothing is guessed. `defaults` applies to both — the short form is a shorter way to say the same thing, never a quieter way to say something else.
- **`defaults` rather than anchors.** The vendored parser tokenises `&`/`*` and nothing downstream reads them, so anchors do not work and would need real parser work to fix. `defaults` covers what people reach for anchors to do, and can be given errors of its own. It applies per key with no merging at depth; `env` is the single exception, and is a mapping for exactly that reason.
- **Four condition words over five states.** The file says `started`, `ready`, `done`, `ok`. The Supervisor still tracks five, because `ready` means "the probe passed" for a service with `ready.http`/`ready.exec` and "the line appeared" for one with `ready.log`. Which of the two it is gets decided at load time by looking at the service being waited on, so the file never has to name a distinction it does not care about.
- **Every service has a Ready state.** A service with no `ready:` block is Ready as soon as it starts. That keeps `after:` usable against something with no observable ready signal, which is a real category — a file watcher, a proxy. It is warned about rather than refused, because refusing would force a fake probe and staying silent would let "waits for the database" quietly mean "waits for the database's pid".
- **Durations carry units, signals carry names.** `grace: 5s` and `signal: SIGINT`, matching `--since 30s` and `--timeout 2m` on the command line. A bare number is seconds, as it already is there. Names rather than numbers because a number is not portable: SIGUSR1 is 10 on Linux and 30 on macOS, so `signal: 10` would mean two things on two machines while looking identical.
- **`ready.http` is a URL.** One string in place of `{host, scheme, path, port}`. Both of the Probe's limits — plain HTTP only, IPv4 or `localhost` only — are checked while reading the file, so they land on the terminal that typed `devrun up` rather than becoming a service that never turns Ready.

## Consequences

- A repo moving to devrun writes a new file. There is no compatibility mode and no automatic reading of `process-compose.yaml`; a one-shot converter is worth writing and has not been.
- Both `devrun.yml` and `devrun.yaml` are read, and having both in one repo is refused. Precedence would decide which file is live by a rule nobody reads, and the dead one would go on being edited.
- Flow mappings (`after: {db: ready}`) cannot be used. The vendored parser resolves them to an empty value rather than failing, so `expectMap` and `mapAfter` turn that silence into a message naming the cause. See `src/vendor/yaml/PROVENANCE.md`.
- Internal field names did not change. `Worker.working_dir`, `.dotenv`, `.environment`, `.depends_on`, `.readiness_probe`, `.ready_log_line` and `.shutdown` are what the file's `dir`, `env_file`, `env`, `after`, `ready` and `stop` map onto. The Supervisor, the Probe and the TUI were untouched by this change, which is most of why it was a day rather than a week.
