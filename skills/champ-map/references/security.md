# ChampMap Security Guide

Read this before writing public methods or handling caller-provided keys.

## Use this file when

- keys come from users or other canisters
- a public method ingests map-like data
- the user wants composite keys
- the user wants to process a large map inside one message

## Main risks

### Hash flooding

Attackers can submit keys that collide and force slow scans in collision buckets.

Use `withSeed` and keep the seed canister-local:

```motoko
let seed : Nat32 = 0x1234_5678;
let seeded = CM.withSeed<Principal>(seed, CM.phash);
```

Use the same seeded hash utils consistently for that map.

### Forged `CM.Map<K, V>` values

`CM.Map<K, V>` is a structural type. A caller can forge malformed shapes.

Prefer this:

```motoko
public func ingest(entries : [(Principal, Nat)]) : async () {
  let seeded = CM.withSeed<Principal>(perCanisterSeed, CM.phash);
  store := CM.fromIter(entries.vals(), seeded);
};
```

If you must accept `CM.Map<K, V>`, validate first:

```motoko
public func acceptMap(m : CM.Map<Principal, Nat>) : async { #ok; #err : Text } {
  switch (CM.validate(m, CM.phash)) {
    case (#ok) { #ok };
    case (#err msg) { #err msg };
  };
};
```

### `useHash` and `calcHash` misuse

These helpers are not general-purpose hash utils. If used as the canonical hash utils for a map, they can collapse all keys into one bucket.

Use them only for narrow, short-lived single-key flows.

### Large bulk operations

`fromIter`, `forEach`, `filter`, `mapFilter`, `map_`, and `equal` can exhaust the IC instruction budget on large maps.

Use bounded batching:

```motoko
let iter = CM.entries(bigMap);
var batch = CM.collectBatch(iter, 5_000);
while (batch.size() > 0) {
  // process batch
  batch := CM.collectBatch(iter, 5_000);
};
```

### Composite attacker-controlled keys

Use `combineHash` for tuples. If any part is attacker-controlled, wrap the combined hash utils with `withSeed`.

## Checklist for public-facing code

- Use `withSeed` for attacker-controlled keys.
- Accept `[(K, V)]` instead of `CM.Map<K, V>` when possible.
- Call `validate()` before trusting an externally supplied `CM.Map<K, V>`.
- Batch large scans with `collectBatch`.
- Mention these tradeoffs explicitly when reviewing user code.
