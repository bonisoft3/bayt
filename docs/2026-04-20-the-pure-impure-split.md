# The pure/impure split

Why CUE generates and nushell runs, and where the boundary is drawn.

## Pure / impure split

CUE handles everything without side effects. Nushell handles everything with side effects. Drawing the boundary cleanly is what keeps the system testable, hashable, and relocatable.

**Pure (CUE):**

- Schema definitions (`#target`, `#cmd`, output blocks)
- DAG construction from `deps:`
- Priority sort for rulemaps (`#MapAsList` → `#MapToList`)
- Emission of bytes (Dockerfile text, YAML for compose/skaffold/taskfile, JSON for vscode/target-manifests, HCL for bake)
- Hash recipe shapes (which files feed which hash, as declarations)

**Impure (nushell):**

```
plugins/bayt/runtime/cache.nu         # L0: hash-check (Taskfile status:) + hash-stamp (post-cmd)
                                      # L1/L2: HTTP GET/PUT to bazel-remote AC endpoint
plugins/bayt/runtime/pin-bases.nu     # refresh bases.lock.cue digests via skopeo/docker manifest
plugins/bayt/runtime/generate-bayt.nu # run CUE, write .bayt/ files, git-stage hidden dir
plugins/bayt/runtime/lint-bayt.nu     # verify project.name matches dir, copy-paste hasn't drifted
```

Rules of thumb:

- **Never shell out from CUE**, even via `tool/exec`. That's the impure bit; it belongs in the runtime layer. CUE evaluation must be deterministic and sandboxable.
- **Never compute hashes in CUE.** Hashes need real file contents. CUE doesn't read the filesystem (outside `tool/file`, which we avoid for the same reason).
- **The boundary is the emitted `.bayt/targets/<n>.json`.** CUE emits a JSON manifest per target describing its portable action. `cache.nu` reads that JSON plus the globbed files to compute hashes. This makes the CUE layer cache-stable (manifest is deterministic) and the nushell layer replaceable (swap `cache.nu` backends without touching CUE).

The generator pipeline:

```
bayt.cue ──cue export──► .bayt/targets/<name>.json ──generate-bayt.nu──► .bayt/<name>.Dockerfile
                                                                        .bayt/compose.<name>.yaml
                                                                        .bayt/Taskfile.<name>.yaml
                                                                        .bayt/skaffold.<name>.yaml
                                                                        (merged) .vscode/tasks.json
                                                                        (merged) docker-bake.hcl
```

`cue export` is pure. `generate-bayt.nu` writes files and git-stages them.
