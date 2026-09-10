# What onboarding taught

Written from putting real projects on bayt. The project list is the one that
existed when it was written; what holds is what each onboarding cost.

## Dogfood

Three concrete examples. Targets in order of increasing overrides.

### `plugins/sayt/bayt.cue` — ~3 non-boilerplate lines

Sayt self-hosts on the most opinionated stack. Everything defaults.

```cue
package sayt
import saytstack "github.com/bonisoft3/bayt/stacks/saytstack"

#sayt: saytstack.#saytProject & {
    dir:  "plugins/sayt"
    name: "sayt"
}

// Emitters.
taskfiles:  (bayt.#emitTaskfiles  & {project: #sayt}).out
dockerfiles: (bayt.#emitDockerfiles & {project: #sayt}).out
composes:   (bayt.#emitComposes   & {project: #sayt}).out
skaffolds:  (bayt.#emitSkaffolds  & {project: #sayt}).out
```

### `guis/app/bayt.cue` — ~12 lines

Web adds a k8s image name and an expose for `launch`.

```cue
package web
import pnpm "github.com/bonisoft3/bayt/stacks/pnpm"

#web: pnpm.#pnpmProject & {
    dir:  "guis/app"
    name: "web"

    targets: {
        "release": {
            skaffold:   image:  "gcr.io/example-proj/guis.app"
            dockerfile: expose: [8080]
        }
        "launch":    dockerfile: expose: [3000]
        "integrate": dockerfile: secrets: ["host.env"]
    }
}
```

### `services/api/bayt.cue` — ~25 lines

The api project adds cross-project deps (proto generation, shared config) and secret-mounted integration.

```cue
package api
import (
    gradle "github.com/bonisoft3/bayt/stacks/gradle"
    proto "bonisoft.org/libraries/proto"
    tbl    "bonisoft.org/libraries/tables"
    log    "bonisoft.org/libraries/logging"
    cfg    "bonisoft.org/libraries/config"
    fw     "bonisoft.org/libraries/framework"
    tc     "bonisoft.org/plugins/toolchain"
)

#api: gradle.#gradleProject & {
    dir:  "services/api"
    name: "api"

    targets: {
        "build": deps: [
            proto.#x.targets.generate,
            tbl.#p.targets.generate,
            cfg.#l.targets.build,
            log.#l.targets.build,
            fw.#m.targets.build,
            tc.#j.targets.build,
        ]

        "integrate": {
            // Integration tests need docker-in-docker plus a host.env secret.
            cmd: "builtin": dockerfile: inject: secrets: [
                {id: "host.env", var: path: "HOST_ENV_FILE"},
            ]
            dockerfile: secrets: "host.env": null
        }

        "release": {
            skaffold: image: "gcr.io/example-proj/services.api"
            // Swap to scratch base + java entrypoint for jib.
            dockerfile: stage: "scratch"
        }
    }
}
```

### Target file count comparison

Each service emits ~8 files from one hand-written bayt.cue:

| Project | Before (hand-maintained) | After (bayt.cue + .bayt/) |
|---|---|---|
| services/api | 5 files, ~320 lines | 1 file (25 lines) + 8 generated |
| guis/app | 5 files, ~240 lines | 1 file (12 lines) + 8 generated |
| plugins/sayt | 4 files, ~180 lines | 1 file (3 lines) + 8 generated |
