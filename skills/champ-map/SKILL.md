---
name: champmap
description: >
  Use this skill when the user wants to write, debug, migrate, or review Motoko code that uses
  ChampMap (`mo:champ-map`) in an app or canister. TRIGGER when the user mentions "champ-map",
  "ChampMap", "mo:champ-map", "persistent map Motoko", "key-value canister", "hash map Motoko",
  "withSeed", "collectBatch", "hash flooding" in Motoko, "migrate from mo:map", or asks how to
  store many key-value pairs on the Internet Computer. Also trigger when the user needs help
  choosing between ChampMap and other Motoko map libraries. DO NOT trigger for generic hash map
  questions in other languages, generic tree/data-structure questions, or unrelated Motoko code
  that does not involve map selection or ChampMap usage.
---

# ChampMap Skill

Use this skill to help a user use `mo:champ-map` correctly inside their own Motoko project.

## Mission

- Produce working Motoko code, not just API descriptions.
- Prefer end-to-end examples over isolated function lists.
- Optimize for correct library usage in a real canister or package.
- Flag security or scale risks when they materially affect the code.

## First decisions

Make these decisions before writing code.

| Question | Choose | Why |
|---|---|---|
| Need a persistent/functional hash map that scales well? | `ChampMap` | Good default for large keyed state. |
| Need insertion order or ordered iteration? | `mo:core/pure/Map` | ChampMap does not preserve order. |
| Migrating from `mo:map` because of scale issues? | `ChampMap` | Avoids the large rehash wall. |
| Keys come from untrusted callers? | `ChampMap` + `withSeed` | Reduces hash-flooding risk. |
| Only need a tiny local map and no ChampMap context? | Consider another map | Do not force ChampMap without reason. |

## Installation

If the user is setting up a `mops` project, add the package first:

```bash
mops add champ-map
```

This adds `champ-map` to `mops.toml`. In the standard `mops` workflow, no extra `dfx.json` wiring is needed.

## Core rules

1. Import as `import CM "mo:champ-map";`
2. Treat the map as immutable. Every write returns a new map.
3. Reassign every mutation: `store := CM.put(store, nhash, key, value);`
4. Pass `HashUtils<K>` to every keyed operation.
5. Use built-in hash utils for primitive keys.
6. Use `CM.combineHash` for tuple keys.
7. Use `CM.withSeed` when keys come from untrusted input.
8. Do not promise insertion order.
9. For public Candid inputs, prefer `[(K, V)]` over accepting `CM.Map<K, V>` directly.

## Read references only when needed

- Read `references/api.md` when you need exact signatures, less-common functions, or a quick lookup.
- Read `references/security.md` before writing public methods, ingesting caller-provided keys, or accepting map-shaped input.

## Pick the right `HashUtils`

| Key type | Use |
|---|---|
| `Nat` | `CM.nhash` |
| `Nat8` | `CM.n8hash` |
| `Nat16` | `CM.n16hash` |
| `Nat32` | `CM.n32hash` |
| `Nat64` | `CM.n64hash` |
| `Int` | `CM.ihash` |
| `Int8` | `CM.i8hash` |
| `Int16` | `CM.i16hash` |
| `Int32` | `CM.i32hash` |
| `Int64` | `CM.i64hash` |
| `Text` | `CM.thash` |
| `Principal` | `CM.phash` |
| `Blob` | `CM.bhash` |
| `Bool` | `CM.lhash` |
| `(K1, K2)` | `CM.combineHash(hu1, hu2)` |

Composite key example:

```motoko
let pairHash = CM.combineHash(CM.nhash, CM.thash); // HashUtils<(Nat, Text)>
var m = CM.empty<(Nat, Text), Nat>();
m := CM.put(m, pairHash, (42, "alice"), 1);
```

If keys cross a trust boundary, wrap the chosen hash utils:

```motoko
let seeded = CM.withSeed<Principal>(seed, CM.phash);
```

## Pick the right write function

| Need | Use |
|---|---|
| Insert or overwrite | `put` |
| Insert and get the old value | `swap` |
| Overwrite only if key exists | `replace` |
| Insert and learn whether key was new | `insert` |
| Compute next value from current value | `update` |
| Remove only | `remove` |
| Remove and learn whether key existed | `delete` |
| Remove and get old value | `take` |

Default to `put` unless the caller needs one of the extra return values.

## Pick the right transform

| Need | Use | Why |
|---|---|---|
| Change values, keep keys and structure | `map` | Fastest value-only transform. |
| Rebuild while changing values | `map_` | Needed when rebuilding is acceptable. |
| Keep a subset | `filter` | Standard selective rebuild. |
| Transform and drop in one pass | `mapFilter` / `filterMap` | Fewer passes. |

Prefer `map` over `map_` when only the values change.

## If the user asks for a canister store

Produce a complete actor snippet with a stable map and matching hash utils.

```motoko
import CM "mo:champ-map";

actor Store {
  let { nhash } = CM;

  // Map<K, V> is a structural type — stable var survives canister upgrades.
  stable var users = CM.empty<Nat, Text>();

  public func putUser(id : Nat, name : Text) : async () {
    users := CM.put(users, nhash, id, name);
  };

  public query func getUser(id : Nat) : async ?Text {
    CM.get(users, nhash, id);
  };

  public query func countUsers() : async Nat {
    CM.size(users);
  };
};
```

## If the user asks for `Principal` keys

Use `CM.phash`. If the principals come from callers, seed the hash utils and use the seeded value consistently.

For a persistent actor, prefer a pattern like this:

```motoko
import CM "mo:champ-map";
import Principal "mo:core/Principal";
import Nat32 "mo:core/Nat32";

shared(deployer) persistent actor class Registry() {
  let admin = deployer.caller;

  // Persist the seed; rebuild the derived HashUtils at runtime.
  let seed : Nat32 = 0x1234_5678;
  transient let pHash = CM.withSeed<Principal>(seed, CM.phash);

  var balances = CM.empty<Principal, Nat>();

  public shared(msg) func setBalance(who : Principal, amount : Nat) : async () {
    if (msg.caller != admin) return;
    balances := CM.put(balances, pHash, who, amount);
  };

  public query func getBalance(who : Principal) : async ?Nat {
    CM.get(balances, pHash, who);
  };
};
```

If the user is not using persistent actors, still keep the same rule: store the seed, derive the seeded `HashUtils`, and use that same seeded value for every operation on the map.

## CRUD pattern by access type

Prefer these patterns when generating application code:

| Access pattern | Complexity | Use |
|---|---|---|
| `get`, `has`, `put`, `remove`, `swap`, `update` by key | O(1) | Default CRUD path |
| `entries`, `toArray`, `filter`, `mapFilter`, name/tier scans | O(n) | Admin/reporting path |

When the primary lookup key is known, model the API around that key. Do not scan by value if a keyed lookup is available.

## If the user asks for CRUD code

Generate code that separates O(1) keyed operations from O(n) scans.

Use this pattern:

```motoko
public shared(msg) func createKin(name : Text) : async { #ok; #err : Text } {
  if (CM.has(kins, pHash, msg.caller)) return #err("already exists");
  kins := CM.put(kins, pHash, msg.caller, { owner = msg.caller; name });
  #ok;
};

public query func getKin(who : Principal) : async ?Kin {
  CM.get(kins, pHash, who);
};

public shared(msg) func updateKinName(newName : Text) : async { #ok; #err : Text } {
  switch (CM.get(kins, pHash, msg.caller)) {
    case null { #err("not found") };
    case (?record) {
      kins := CM.put(kins, pHash, msg.caller, { record with name = newName });
      #ok;
    };
  };
};

public shared(msg) func deleteKin(who : Principal) : async { #ok; #err : Text } {
  if (not CM.has(kins, pHash, who)) return #err("not found");
  kins := CM.remove(kins, pHash, who);
  #ok;
};
```

Prefer `CM.update` when the new value is naturally computed from the old one.

## If the user asks to transform all values

Use `CM.map` for bulk value transforms. This is O(n) but preserves the trie structure without rebuilding.

```motoko
// Mass upgrade: all "free" users become "pro"
kins := CM.map<Principal, Kin, Kin>(kins, func(_, record) {
  if (record.tier == "free") { { record with tier = "pro" } } else { record };
});
```

## If the user needs the old value when replacing

Destructure the tuple returned by `swap`:

```motoko
let (updated, oldValue) = CM.swap(kins, pHash, msg.caller, newRecord);
kins := updated;
// oldValue is null if key was new, ?record if it replaced an existing entry
```

## If the user asks to update from existing state

Show `CM.update` when the logic depends on the previous value:

```motoko
kins := CM.update<Principal, Kin>(kins, pHash, who, func(existing) {
  switch existing {
    case null { null };
    case (?record) { ?{ record with tier = "pro" } };
  };
});
```

Use `put` when the caller already has the full replacement value. Use `update` when the change is derived from the existing value.

## If the user asks to ingest caller-provided data

Do not accept `CM.Map<K, V>` directly unless the user explicitly needs that shape.

Prefer this:

```motoko
public func ingest(entries : [(Principal, Nat)]) : async () {
  let seeded = CM.withSeed<Principal>(perCanisterSeed, CM.phash);
  store := CM.fromIter(entries.vals(), seeded);
};
```

If the user must accept a `CM.Map<K, V>`, read `references/security.md` first and validate it before use.

## If the user asks to process a large map

Warn that bulk operations can exceed the per-message instruction budget.

Use chunking:

```motoko
let iter = CM.entries(store);
var batch = CM.collectBatch(iter, 1_000);

while (batch.size() > 0) {
  // process batch
  batch := CM.collectBatch(iter, 1_000);
};
```

Single-key operations like `get`, `put`, and `remove` are safe at any map size.

Approximate safe limits per message (~5 billion instructions, ~50-byte keys/values):

| Operation | Safe up to |
|---|---|
| `entries`, `forEach`, `toArray`, `size` | ~200K entries |
| `filter`, `mapFilter`, `map_`, `fromIter` | ~100K entries |
| `equal` | ~50K entries |
| `toText` | capped at 1000 by default (use `toTextLimit` to adjust) |

For medium-size admin scans, `filter` plus `toArray` is often fine. For very large maps, prefer `entries` plus `collectBatch`.

## If the user asks for filtered lists or admin reports

It is fine to use O(n) scans for admin-only or bounded reporting paths. Make that tradeoff explicit.

```motoko
import Iter "mo:core/Iter";

public query func getByTier(targetTier : Text) : async [Kin] {
  let filtered = CM.filter<Principal, Kin>(kins, pHash, func(_, record) {
    record.tier == targetTier;
  });
  let pairs = CM.toArray(filtered);
  Iter.toArray(Iter.map<(Principal, Kin), Kin>(pairs.vals(), func((_, r)) { r }));
};
```

Do not describe these as O(1). Call out that they scan the map.

## If the user asks to migrate from `mo:map`

Explain the semantic differences and then show before/after code.

```motoko
// before
import Map "mo:map/Map";

let users = Map.new<Nat, Text>();
Map.set(users, Map.nhash, 1, "alice");
let user = Map.get(users, Map.nhash, 1);

// after
import CM "mo:champ-map";

let { nhash } = CM;
var users = CM.empty<Nat, Text>();
users := CM.put(users, nhash, 1, "alice");
let user = CM.get(users, nhash, 1);
```

Always mention:

- ChampMap is immutable, so every write must be reassigned.
- ChampMap does not preserve insertion order.
- ChampMap scales much better for very large maps.

## If the user asks whether to use ChampMap

Recommend `ChampMap` when the user needs:

- keyed canister state
- persistent/functional updates
- large map scale
- hash-map semantics instead of ordered-map semantics

Recommend something else when the user needs:

- insertion order
- sorted traversal
- generic map advice outside Motoko or outside the Internet Computer context

## Do not do these things

- Do not write `CM.put(store, nhash, k, v);` without reassigning the result.
- Do not use `useHash` or `calcHash` as the long-lived hash utils for a map.
- Do not accept `CM.Map<K, V>` from public input without validation.
- Do not forget `withSeed` when attacker-controlled keys matter.
- Do not use `toText` on a large map without mentioning its cost and default cap.
- Do not recommend ChampMap when the user explicitly needs ordered behavior.

## Response shape

- Give the user copy-pasteable Motoko code when they ask how to implement something.
- Mention `HashUtils` explicitly whenever you show keyed operations.
- Mention `withSeed` whenever keys come from callers or untrusted sources.
- Mention order semantics when comparing against another map library.
- Keep explanations short unless the user asks for a deeper comparison.
