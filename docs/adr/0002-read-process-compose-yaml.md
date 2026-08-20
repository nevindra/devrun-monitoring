# Read process-compose.yaml directly rather than defining our own config format

**Superseded by [0008](0008-devrun-yml.md).** Kept because the reasoning it was reversed for is only legible next to the reasoning it replaced.

devrun reads the repo's existing `process-compose.yaml`, supports a strict subset of its schema, and fails loudly on any field it does not understand.

The goal is coexistence: a teammate keeps running `process-compose up` against the same repo while we run `devrun up`, and neither has to care. A separate `devrun.yaml` would technically work, but it only converts the problem into permanent manual synchronisation — a service added to one file and forgotten in the other is a bug that surfaces as "works on my machine" weeks later.

## Consequences

- We inherit someone else's schema, including `${VAR}` substitution and dotenv loading. The surface is smaller than it looks: the real config uses twelve fields, two probe kinds, and one dependency condition.
- An unsupported field must stop startup with a clear message. Silently ignoring one is precisely the failure this decision exists to prevent — it would let two people run the same file and get different behaviour, with nothing on screen to say why.
- YAML is locked in as the config language. TOML and JSON are not available to us.
