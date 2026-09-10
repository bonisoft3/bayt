# Pending

What is argued but not built. A line leaves this file when it lands or when it
is refused in writing; a refusal belongs in a dated doc under `docs/`, not here.

Open items not yet implemented. The list shrunk substantially as the implementation landed; what remains is genuinely future work, not undecided design.

### HMR emission

Compose `develop.watch`, Skaffold `sync.manual`, and Taskfile `--watch` have overlapping but distinct capabilities. Design sketch:

- `develop: watch: [...]` lives on `#composeBlock`.
- Skaffold block mirrors with `sync.manual: [...]` generated from the compose watch entries (same path/target schema).
- Taskfile gets a `<name>:watch` pseudo-task that re-runs on source changes using go-task's `watch: true`.
- Nest where possible: compose's HMR is natively layered inside `skaffold dev`.

### Non-file outputs (e.g., deploy actions, network calls)

`release` → `skaffold run` pushes to a registry; `verify` → runs against a live preview. Neither produces a local file. The cache key is still input-based, but the side effect (`kubectl apply`, HTTP POST) is what matters. These run unconditionally when invoked — idempotency is the contract, not caching.

### Watch mode across generators

`bayt watch` (impure, nushell) would re-run the generator on `bayt.cue` / `images.lock.cue` / imported CUE file changes. Combined with Taskfile's own watch: edit target → `.bayt/*` regenerates → running task picks up the change → rebuild triggers via Taskfile `sources:`. Chained HMR. Not yet built; today users invoke `just sayt generate` manually after editing bayt.cue.

### `bayt.cue` authoring ergonomics

CUE's error messages on unification conflicts are dense. Mitigations on the table:

1. Close schemas (`close({...})`) aggressively so typos surface as "field not allowed" rather than silent drift. Partially in place.
2. Ship `plugins/bayt/bayt-schema.json` for IDE/vscode CUE plugin consumption. Not yet.
3. `bayt lint` (impure) validates the `bayt.cue` against the schema and offers suggestions. Not yet.
