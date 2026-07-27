// depot.cue — depot.dev cache + build/run-split distribution recipe for sayt
// projects. Org-agnostic: the ids are ${DEPOT_PROJECT_ID}/${DEPOT_ORG_ID} refs,
// so a call site supplies the concrete "${…:-fallback}" values. Unify `.out`
// into a #project.
package sayt

// depot — bake.cache on the project Cache registry and bake.images pull
// distribution on the org Registry. scope is the cache namespace
// ("<name>-bake-cache-v<N>"). The runtime-closure group every project emits
// (.bayt/depot.hcl) needs no opt-in.
depot: D={
	projectId: *"${DEPOT_PROJECT_ID}" | string
	orgId:     *"${DEPOT_ORG_ID}" | string
	scope:     string
	out: {
		bake: {
			cache: {type: "registry", registry: "registry.depot.dev/\(D.projectId)", scope: D.scope}
			images: {pull: true, registry: "\(D.orgId).registry.depot.dev/\(D.projectId)"}
		}
	}
}
