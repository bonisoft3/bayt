# The three-tier cache

What each layer skips, and why a tool's own cache composes with bayt's rather
than competing with it.

## Three-tier cache model

Three layers that compose orthogonally. Each has a different scope, different speed, and a different failure mode. BuildKit's layer cache is a fourth dimension that runs in parallel inside Docker.

| Layer | Engine | Cache key | Scope | Speed |
|---|---|---|---|---|
| **L0: hash-stamp** | `fingerprint.nu hash-check` via go-task `status:` | SHA-256 of (platform-key ∪ srcs ∪ direct-dep stamps), Merkle-chained. platform-key = kernel + arch + libc flavor (musl/glibc) | Same worktree | ~50 ms |
| **L1/L2: cache.nu** | local-FS (default) / buchgr/bazel-remote / ORAS — selected by env | Same hash as L0 | Local FS: same machine. bazel-remote/ORAS: cross-machine, shared with CI. | Local FS: ms. Remote: network-bound |
| **BuildKit layers** | Docker BuildKit content-addressed store | Layer input hashes (Dockerfile slice + COPY'd bytes) | Per-host + registry if configured | — |

### L0: hash-stamp

Pure nushell. Called from go-task's `status:` hook.

```yaml
# .bayt/Taskfile.build.yaml (generated)
tasks:
  default:
    deps:
      - ::bayt:setup
    status:
      - mise x -- nu {{.TASKFILE_DIR}}/../../../plugins/bayt/runtime/fingerprint.nu hash-check --manifest {{.TASKFILE_DIR}}/bayt.build.json
    cmds:
      - defer: '{{if not .EXIT_CODE}}mise x -- nu {{.TASKFILE_DIR}}/../../../plugins/bayt/runtime/fingerprint.nu hash-stamp --manifest {{.TASKFILE_DIR}}/bayt.build.json{{end}}'
      - mise x -- nu {{.TASKFILE_DIR}}/../../../plugins/bayt/runtime/cache.nu run --manifest {{.TASKFILE_DIR}}/bayt.build.json --full -- mise x -- ./gradlew assemble
```

The status line is intentionally minimal — every input the hash depends on lives in `.bayt/bayt.<n>.json`, including:

- `srcs.globs` / `srcs.exclude` — direct content inputs (globs / exclusions).
- `outs.globs` — what hash-check additionally probes for existence (cheap `generates:` substitute; missing outs force a rerun, letting cache.nu refetch instead of rebuilding).
- `chainedDeps` — `[{name, project, dir}]` for each direct dep that itself produces a stamp. fingerprint.nu folds each dep's `.task/bayt/<n>.hash` file into the input set.

**Merkle chain semantics.** Hashing a dep's stamp file (rather than the dep's srcs) is what makes invalidation propagate transitively in O(direct deps) per status check:

```
stamp(T) = hash(platform-key ∪ manifest(T) ∪ srcs(T) ∪ {content-of stamp(d) for d in directDeps(T)})
```

Because go-task processes deps strictly before evaluating the parent's `status:`, each dep's stamp file on disk is fresh by the time it's read. A change to any leaf bubbles up one layer at a time: the leaf's stamp flips, the next layer's hash sees the new bytes, that layer's stamp flips, and so on. No recursive walk in CUE or nushell — the chain is constructed by go-task's natural dep-first execution order. The same key recipe powers cache.nu's L1/L2 lookups, so local and remote cache decisions stay coherent.

**Path math** (relative `../` traversal for cross-project chained deps) lives in fingerprint.nu, not CUE — nushell's `path` library handles separators correctly and avoids CUE's brittle string concat. CUE only emits the raw `{name, projectDir}` tuple per chained dep.

`hash-stamp` runs as the tail of `cmds:` and atomically writes the new stamp (tmp + rename). hash-check fails fast on missing literal files or git-hash-object errors — no silent fallbacks, so a misconfigured srcs list surfaces immediately rather than poisoning the cache.

Works in containers, Windows, air-gapped CI — no dependencies beyond nushell + git.

### L1 / L2: cache.nu

`cache.nu run --manifest <path> [--full] [--similar] -- <cmd>` wraps every Taskfile cmd. The bayt emitter inserts the wrap automatically — projects don't write the invocation themselves; the per-target capabilities `bayt.cache.full` / `bayt.cache.similar` toggle the flags.

```
1. Resolve the manifest, compute hash (same algorithm as L0).
2. backend-get hash  →  EXACT hit: restore outs to declared paths.
3. If --full and EXACT hit: exit 0 (trust the restored outs, don't run cmd).
4. If --similar and EXACT miss: pick the closest cached entry (weighted
   intersection over inputs + user/branch/day) and restore as warm state.
5. Otherwise run cmd; gradle/cargo/vitest see warm outputs and no-op fast.
6. On miss + cmd success: backend-put outputs.
```

Backend selected by env (first match wins):
- `BAYT_CACHE_URL` → buchgr/bazel-remote HTTP. Payload files go to `/cas/<sha256>`, one blob each; the entry — `[{path, size, sha256, exec}]` — goes to `/ac/<hash>`. Addressing payload by content is what lets a file shared by two entries, the common case since most outs survive a rebuild, be stored and transferred once rather than per entry; it also carries raw bytes, where a single-blob entry format would need an encoding wrapper. The entry's address folds in a format tag, so a client speaking a different entry format lands on a different key rather than reading a body it cannot parse. The entry is not a REAPI ActionResult, so the server must run with `--disable_http_ac_validation`; the CAS half needs no flag, since bazel-remote validates each upload against the digest in its URL. bazel-remote chains to S3/GCS/Azure or proxies to depot.dev / BuildBuddy via its own flags — cross-machine + remote-storage live at the bazel-remote layer.
- `BAYT_CACHE_REGISTRY` → ORAS OCI registry. Each entry tagged `<project>-<target>-<hash[0:16]>`. Registry's GC policy (untagged-image cleanup) handles eviction.
- (default) → local FS at `BAYT_CACHE_DIR` (XDG-aware default: `$XDG_CACHE_HOME/bayt` or `~/.cache/bayt`), sharded by 2-char hash prefix. Atomic publish via tempdir + rename. mtime LRU GC at end of every `generate-bayt.nu` run, budget set by `BAYT_CACHE_MAX_SIZE`.

`bayt.cache.full` per-target capability trades correctness-checking-by-cmd for raw speed: on EXACT hit, skip cmd entirely. The gradle stack opts into this for `assemble` and `integrationTest` because the daemon cold-start is too costly to pay on every cache hit. Sibling capability `bayt.cache.similar` opts into warm-restore on EXACT miss (closest entry by weighted intersection over inputs + user/branch/day) — opt-in per project until real workloads validate the win.

Errors that recover (warn + treat as miss): backend GET failure, manifest unresolvable. A restore that fails partway does not leave the workspace half-populated — it clears the target's declared outs first, so the rerun starts from nothing rather than from a mix that the following store would publish as a complete payload. Errors that die (no swallowing): backend PUT failure, missing oras CLI when ORAS is configured, GC failure.

Cache key is input-only: `hash(platform-key ∪ srcs ∪ direct-dep stamps)`. Toolchain version changes invalidate naturally because `.mise.toml` and `mise.lock` flow through the workspace-root setup target's outs into every consumer's hash.

### BuildKit: orthogonal

Docker builds use BuildKit's content-addressed layer cache. `COPY --link` means layer ordering doesn't matter for cache independence — changing srcs for target B doesn't invalidate layers for target A. Cache mounts (`--mount=type=cache`) persist tool caches (Gradle `~/.gradle`, pnpm `~/.pnpm`, Go `~/.cache/go-build`) across builds. Registry cache (`cacheFrom` / `cacheTo` in the bake block) shares layers cross-machine.

### Composition

L0 gates whether the command runs at all. L1/L2 gate whether the command's work gets reused across worktrees or machines. BuildKit gates whether individual Docker layers get rebuilt. Each is independent; enabling or disabling any one doesn't affect the others.

Failure modes are distinct: L0 false-negative (stamps invalidated unnecessarily) costs one command run. L1/L2 miss costs network + one command run. BuildKit miss costs a layer rebuild.
