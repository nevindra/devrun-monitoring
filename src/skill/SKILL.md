---
name: devrun
description: Run a project's local dev services with devrun and read all their logs in one place. Use when starting or restarting a repo's dev server or dev stack (db, api, web, worker), when the repo has a devrun.toml or AGENTS.md mentions devrun, when a request or service fails and you need logs across every service (errors, panic, ERROR, "address in use", "connection refused"), when a service will not become ready, when running an e2e suite against the local stack, or when writing or fixing a devrun.toml. Prefer it over backgrounding `pnpm dev` and reading one process's output. Not for production deploys, containers in production, or CI orchestration beyond a single e2e run.
---

# devrun

devrun starts every service in `devrun.toml`, writes each one's output to a plain file, and answers questions about all of them in one command. Linux and macOS.

## Rules

- From an agent, always `devrun up --detach`. Plain `devrun up` stays in the foreground until the Session ends (a TUI on a terminal), which blocks you.
- Run `devrun status` before starting. One Session per directory: if one is up, use it, do not start a second.
- If you started the Session, end it with `devrun down` when you are done.
- Do not background `pnpm dev` and read one process's output. The error is usually in another service.

## Core loop

```console
$ devrun up --detach        # returns once every service is ready; non-zero if any failed
$ devrun errors             # exit code 1 while anything is broken; prints the log tail
$ devrun logs --since 2m    # every service, merged by time
$ devrun status             # state of each service (--json for data)
$ devrun restart NAME       # one service (NAME covers all its replicas)
$ devrun down               # stop everything
```

Branch on exit codes instead of reading prose:

| command | non-zero when |
|---|---|
| `devrun up --detach` | a service failed to come up inside `--timeout` (default 2m) |
| `devrun wait --timeout 90s` | not ready when the clock runs out |
| `devrun errors` | anything is broken right now |
| `devrun run CMD` | the command failed (`128 + signal` included) |

`errors` also sweeps services that are still up for error-shaped lines (for example `api ERROR upstream refused connection`), which `status` would call healthy.

### Reading logs

```console
$ devrun logs --grep 'panic|ERROR'        # `|` separates alternatives; -i ignores case
$ devrun logs --grep ERROR --tail 5       # last 5 matches, not matches among last 5 lines
$ devrun logs api worker --since 30s      # only some services
$ devrun logs --since 2m --json           # ndjson: {"ts","w","msg"}, ts in epoch ms
$ devrun logs --path                      # print the log file paths instead
```

- `--tail N` defaults to 100 (1000 with `--since`). `--all` removes the limit.
- Output is trimmed by default: ANSI stripped, repeats folded (`×3`), lines clipped at 1200 bytes (`--max-line N`). The end of the output says what was left out. `--raw` gives bytes back untouched.
- `--no-time` drops timestamps. `--since` takes `30s`, `2m`, `1h`, `1d`.
- Files: `.devrun/logs/latest/<name>.log` (`<name>.2.log` for replica 2). `tail`, `grep` and your editor work on them. Older runs sit beside `latest/` (newest 10 kept).

## Starting a subset

```console
$ devrun up api --detach              # api and what it depends on
$ devrun up --profile e2e --detach    # a profile's services and their dependencies
$ devrun up api --no-deps --detach    # only api; a dependency that is off counts as satisfied
$ devrun start worker                 # bring an `off` service into a running Session
```

Services left out are `off`: not a failure, not reported by `errors`, and `wait` counts them as settled. `autostart = false` services start `off`.

Other flags: `-f FILE` (config path, default `devrun.toml`), `--plain` (never draw the TUI), `--keep N`.

## No config: `devrun run`

```console
$ devrun run --detach --ready-log "listening on" pnpm dev
$ devrun run --restart on-failure go run ./cmd/api
```

- devrun's flags go before the command (`--name`, `--cwd`, `--restart POLICY`, `--ready-log TEXT`, `--shell`, `--detach`). Everything after the command passes through untouched.
- `--shell` lets the shell parse the words: `devrun run --shell 'sleep 1; echo hi'`. Use `--` first if the command name starts with a dash.
- Without `--detach` it blocks and exits with the command's status. `logs`, `errors`, `status` and `down` work on it as usual.

## Writing a devrun.toml

File is `devrun.toml` next to where devrun runs. Minimal:

```toml
[services.web]
run = "pnpm dev"
```

### Example

```toml
env_file = ".env"                 # every service gets it

[env]                             # so does this
DATABASE_URL = "postgres://dev:dev@localhost:5432/app"

[templates.node]                  # taken with `extends`
restart = { policy = "on-failure", max = 5, backoff = "1s" }
stop    = { signal = "INT", timeout = "15s" }

[profiles.e2e]                    # devrun up --profile e2e
services = ["e2e"]                # plus everything it depends on
env      = { BASE_URL = "http://localhost:3000" }

[services.postgres]
run   = ["docker", "run", "--rm", "-p", "5432:5432",
         "-e", "POSTGRES_PASSWORD=dev", "postgres:16"]
ready = { exec = "pg_isready -h localhost", every = "2s", failures = 30 }

[services.migrate]
run   = "pnpm db:migrate"
after = ["postgres"]              # waits for postgres to be ready

[services.api]
extends = "node"
run     = "pnpm dev"
cwd     = "apps/api"
env     = { PORT = 3000 }
after   = { migrate = "succeeded" }
ready   = "http://localhost:3000/health"
watch   = ["src"]                 # a change restarts it

[services.worker]
extends  = "node"
run      = "pnpm worker"
after    = ["api"]
ready    = { log = "worker started" }
replicas = 2                      # worker.1 and worker.2

[services.e2e]
run       = "pnpm test:e2e"
after     = { api = "ready" }
autostart = false                 # not part of a plain `devrun up`
restart   = "exit-on-end"         # when the suite ends, so does the Session
```

### Top level

| key | meaning |
|---|---|
| `[services.<name>]` | Required. Names use letters, digits, `-`, `_`, `.` |
| `[templates.<name>]` | Any service fields; used by `extends = "<name>"` |
| `[profiles.<name>]` | `services = [...]`, optional `env = {...}` layered over `[env]` |
| `[env]`, `env_file` | Variables / file(s) for every service (file paths relative to the config) |
| `shell` | What runs commands. Default `["bash", "-c"]` |
| `color` | Default `true`: services get `FORCE_COLOR=1`, `CLICOLOR_FORCE=1`. `false` or `NO_COLOR` in env turns it off |

### Service fields

| key | meaning |
|---|---|
| `run` | Required. String for the shell, or array of words (devrun quotes them) |
| `description`, `cwd` | Shown by `devrun config`; working directory relative to the config |
| `env` | `{ KEY = "value" }`; numbers and booleans become text |
| `env_file` | File or list of files |
| `after` | `["db"]` or `{ db = "ready" }`. Conditions: `started`, `ready`, `exited`, `succeeded` |
| `autostart` | `false`: starts `off` unless a started service depends on it |
| `replicas` | `1` to `64`: `<name>.1` ... `<name>.N`, each with `DEVRUN_REPLICA=k` |
| `watch` | `["src", "go.mod"]` or `{ paths = [...], ignore = [...], debounce = "300ms" }` |
| `restart` | String or table (below) |
| `ready` | Health check (below) |
| `stop` | Shutdown (below) |
| `extends` | Template name |

### `after`

- `after = ["db"]` waits for `db` to be ready if it has a `ready` check, else for it to have started.
- `{ db = "ready" }` needs a `ready` check on `db`. `"succeeded"` waits for a clean exit (migrations). `"exited"` waits for any exit.
- Cycles, waiting on a missing service, or waiting for `ready` on a service with no check are refused when the config loads.

### `ready`

Exactly one of:

- `ready = "http://host:port/path"` (short for `{ http = "..." }`). Plain HTTP; host is an IP or `localhost`. Any 2xx/3xx passes, or set `status = 204` (http only).
- `{ exec = "cmd" }` passes on exit 0.
- `{ log = "text" }` is ready once the text appears in the output.

Timings for `http` and `exec`: `delay` (0), `every` (10s), `timeout` (1s), `successes` (1 in a row to be ready), `failures` (3 in a row to be unhealthy). Durations are whole seconds: `5`, `"5s"`, `"2m"`.

### `restart`

- String: `"no"` (default), `"always"`, `"on-failure"`, `"exit-on-failure"`, `"exit-on-end"`.
- Table: `{ policy = "on-failure", max = 5, backoff = "1s" }`. `max` and `backoff` only with `always` or `on-failure`. `backoff` defaults to `200ms`, doubles up to 30s. After `max` restarts the service stays `failed` (so `errors` reports it); a run lasting 30s resets the count. Set `max` so a boot crash cannot loop forever.
- `exit-on-end`: when that service ends, the whole Session shuts down and devrun exits with its exit status.

### `stop`

`{ signal = "INT", timeout = "15s", command = "docker compose down" }`. Default signal `TERM`, timeout 10s, then `KILL`. `command` (string or array) runs on every stop, with the service's env and cwd, even if the process already exited (useful for `docker compose up -d`). `timeout` bounds the whole stop.

### `watch`

Paths are relative to the service's `cwd`, directories recursive. A change restarts the service, or starts it if it had exited. `.git`, `.devrun`, `node_modules`, `__pycache__`, `.venv`, `.zig-cache`, `zig-out` and editor temp files are ignored by default; `ignore` adds names (`*` wildcard).

### Templates, env, variables

- `extends = "node"` overrides field by field. `env` and `env_file` add up. `stop` merges its fields separately.
- Environment order: what devrun started in, then each `env_file` in order, then `env` (`env` wins).
- `${VAR}`, `$VAR`, `${VAR:-default}`, `$$` expand only in `env`, `env_file`, `cwd` and `ready.http` (looking in top-level `[env]`, top-level `env_file`, then the process environment). `run` and `ready.exec` are not expanded by devrun: the shell sees them as written. `${DEVRUN_REPLICA}` works in the expanding fields.
- `replicas`: `after = ["worker"]` waits for all replicas, `["worker.2"]` for one. `devrun logs worker` and `restart worker` cover all.

### Local overrides

`devrun.local.toml` beside `devrun.toml` (for `-f path/x.toml`: `path/x.local.toml`) is merged over it: tables merge key by key, anything else replaces. For machine-specific ports or tokens; it belongs in `.gitignore`. `devrun config` says when it merged one.

### Validate after every edit

Unknown fields are refused, not ignored. Run `devrun config` after editing (it also takes `devrun config FILE`); it prints what devrun understood, or the error.

| error / symptom | fix |
|---|---|
| `unknown field "command". devrun calls it "run"` | Rename. process-compose names map: `processes`->`services`, `command`->`run`, `working_dir`->`cwd`, `environment`->`env` (a table), `dotenv`->`env_file`, `depends_on`->`after`, `availability.restart`->`restart`, `shutdown`->`stop`, `readiness_probe`->`ready` |
| TOML parse error in `{ ... }` | Inline tables must be on one line |
| parse error on a value | Strings need quotes: `ready = "http://..."`, `env = { A = "x" }` |
| wait for `ready` with no check | Add `ready` to the target, or use `started` |
| `include` or `ready.tcp` | Planned, not available. Use an `exec` or `log` check instead |
| `restart` policy with underscores | Use dashes: `on-failure`, `exit-on-end` |

## Debugging recipes

**A request fails**
1. `devrun errors`. Read the broken service and the error-shaped lines from services still up.
2. `devrun logs --since 2m --grep 'ERROR|panic|refused|timeout' -i` across all services; drop `--grep` to see the full interleaved story around the failure timestamp.
3. Reproduce the request, then `devrun logs --since 30s`.
4. After a fix: `devrun restart NAME` (or rely on `watch`), then `devrun errors` again.

**A service will not become ready**
1. `devrun up --detach` failed or `devrun wait` timed out: `devrun status` shows which service is not ready and its state.
2. `devrun logs NAME --tail 50`, or `tail` its `.devrun/logs/latest/NAME.log`.
3. `devrun config` to see the probe devrun runs (URL, exec, log text, timings). Run the probe by hand (`curl`, the `exec` command). Common causes: wrong port or path, `ready.log` text that never prints, probe `timeout` or `failures` too tight, a dependency in `after` that never became ready.
4. Raise `--timeout` only if the service is genuinely slow.

**E2E run**
1. Define the suite as a service with `after = { api = "ready" }`, `autostart = false`, `restart = "exit-on-end"`, and a `[profiles.e2e]` listing it.
2. `devrun up --profile e2e --plain`. It starts the stack, runs the suite, tears everything down, and exits with the suite's exit status.
3. On failure: `devrun logs --since 5m --grep 'ERROR|panic'` and the suite's own log in `.devrun/logs/latest/`. Logs survive the run.

## Etiquette

- Check `devrun status` first. A Session already up for this directory is the one to use.
- `devrun down` what you started; leave what the user started.
- `devrun clean` deletes saved logs from earlier runs (`--all` for everything); do not run it while debugging.
- `devrun init` writes a short devrun block into the repo's `AGENTS.md` or `CLAUDE.md`, so future agents know the tool exists. Run it when a repo uses devrun but does not mention it.
- `devrun` with no arguments prints the full flag list.
