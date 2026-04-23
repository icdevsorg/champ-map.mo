# ChampMap

A **persistent / functional** hash map for [Motoko](https://internetcomputer.org/docs/current/motoko/main/about-this-guide), built on the **CHAMP** (Compressed Hash-Array Mapped Prefix-tree) data structure.

## Why this library exists

ChampMap was built because [`ZhenyaUsenko/motoko-hash-map`](https://github.com/ZhenyaUsenko/motoko-hash-map) v9 — the de facto Motoko hash map for years — tops out around **4 million records** and then can no longer grow within the IC's per-message cycle limit. Once a `mo:map` instance crosses that threshold, the rehash/resize step on the next insert exceeds the instruction budget and the canister traps, with no safe path to recover other than offloading entries.

ChampMap's CHAMP trie has no global rehash step — each insert touches only the path from the root to one leaf (≤ 7 nodes), so per-message cost stays flat as the map grows. This lets a single map scale well past the 4M wall into the tens of millions of entries on a single canister.

### Trade-off: no insertion order

Unlike `mo:map`, which threads a doubly-linked list through its buckets to preserve insertion order, **ChampMap does not maintain any ordering**. Iteration order is determined by the hash structure of the trie and is stable for a given set of keys, but it is *not* insertion order and *not* key order. As a consequence:

- ChampMap **cannot be used as a FIFO queue** the way `mo:map` can (no `peek`/`pop` of the oldest entry).
- If you need ordered iteration, use a different structure (`mo:core/pure/Map` for key order, `mo:map` for insertion order, or a separate index).\n\n## Why it's faster than `mo:core/pure/Map`

The Motoko core map (`mo:core/pure/Map`) is a balanced red-black tree, so every lookup, insert, and delete walks `O(log n)` levels — a depth that grows without bound as the map grows.

ChampMap is a **fixed-depth** structure. Keys are hashed to a 32-bit value and consumed 5 bits per level, so the trie has **at most 7 levels** regardless of how many entries are stored. Lookups and updates touch a hard-capped number of nodes (~7) instead of `log₂(n)` (which is already 17 at 100K entries and 20 at 1M). On top of that:

- **No rebalancing.** Red-black trees rotate subtrees on every insert/delete; CHAMP only path-copies the affected branch.
- **Cache-friendly nodes.** Each CHAMP branch packs its inline entries and child pointers into two compressed arrays indexed by a 32-bit popcount bitmap, so the hot path is a couple of array reads instead of a chain of pointer hops.
- **Small-map fast-path.** Maps with ≤ 16 entries skip hashing entirely and use a flat array.

The net effect (see [Benchmarks](#benchmarks)) is that `get` is ~46 % faster at 100K entries and `iterate` is roughly 2× faster across all sizes.

## Hash collisions

Key hashes are `Nat32`, so two distinct keys can in principle hash to the same 32-bit value. ChampMap handles this without breaking its `O(1)` guarantees:

1. The trie consumes 5 bits of hash per level. Once the full 32 bits have been consumed (depth 7) and two entries still collide, ChampMap converts that leaf into a **`#collision(hash, entries)`** node — a flat bucket of `(K, V)` pairs that all share the same 32-bit hash.
2. Lookups, inserts, and removes inside a collision bucket fall back to a **linear scan** using the user-supplied `areEqual` from `HashUtils<K>`. The `getHash` function is *not* re-consulted inside the bucket; equality on the original key is the tiebreaker, so there is no risk of a hash-equal/key-distinct pair shadowing each other.
3. Buckets shrink and disappear automatically: removing the second-to-last entry collapses a `#collision` back to an inline trie entry.

For well-distributed hashes (the built-in `HashUtils` for `Nat`, `Text`, `Blob`, `Principal`, etc. all qualify), collision buckets are vanishingly rare and never grow beyond a couple of entries in practice. They exist purely to make correctness independent of hash quality.

## Key features

| Feature | Detail |
|---------|--------|
| **Persistent / immutable** | Every mutation returns a *new* map; the old version is unchanged. Safe for rollback-friendly canister state. |
| **O(1) clone** | `clone` returns the same structural reference — free snapshots. |
| **Hash-based O(1) average lookup** | Path-copying CHAMP trie with 32-way branching at each level. |
| **Small-map fast-path** | Maps with ≤ 16 entries use a flat array (no hashing overhead). |
| **Built-in hash utilities** | Pre-built `HashUtils` for `Nat`, `Nat8`–`Nat64`, `Int`–`Int64`, `Text`, `Blob`, `Principal`, `Bool`, plus combinators. |
| **Zero Prim imports** | Pure `mo:core` — no `import Prim "mo:⛔"`. |

## Install

```bash
mops add champ-map
```

## Quick start

```motoko
import CM "mo:champ-map";

let { nhash } = CM;           // HashUtils<Nat>

var m = CM.empty<Nat, Text>();
m := CM.put(m, nhash, 1, "hello");
m := CM.put(m, nhash, 2, "world");

assert CM.get(m, nhash, 1) == ?"hello";
assert CM.size(m) == 2;

// Clone is O(1) — structural sharing
let snapshot = CM.clone(m);
m := CM.remove(m, nhash, 1);
assert CM.size(m) == 1;
assert CM.size(snapshot) == 2; // unchanged
```

---

## API reference

### Types

```motoko
type HashUtils<K> = (getHash : (K) -> Nat32, areEqual : (K, K) -> Bool);
type Map<K, V>    = { #empty; #arrayMap : [var (K, V)]; #trie : Node<K, V> };
```

### Creating / measuring

| Function | Signature | Description |
|----------|-----------|-------------|
| `empty` | `<K, V>() : Map<K, V>` | Empty map |
| `singleton` | `<K, V>(hashUtils, key, value) : Map<K, V>` | One-element map |
| `isEmpty` | `<K, V>(map) : Bool` | True if no entries |
| `size` | `<K, V>(map) : Nat` | Number of entries |

### Getting

| Function | Signature | Description |
|----------|-----------|-------------|
| `get` | `<K, V>(map, hashUtils, key) : ?V` | Lookup by key |
| `has` / `containsKey` | `<K, V>(map, hashUtils, key) : Bool` | Key membership |
| `find` | `<K, V>(map, hashUtils, key) : ?(K, V)` | Key-value pair lookup |

### Inserting / updating

| Function | Signature | Description |
|----------|-----------|-------------|
| `put` / `set` / `add` | `<K, V>(map, hashUtils, key, value) : Map<K, V>` | Insert or overwrite |
| `swap` | `<K, V>(map, hashUtils, key, value) : (Map<K, V>, ?V)` | Insert/overwrite + return old value |
| `replace` | `<K, V>(map, hashUtils, key, value) : (Map<K, V>, ?V)` | Overwrite only if key exists |
| `insert` | `<K, V>(map, hashUtils, key, value) : (Map<K, V>, Bool)` | Insert + return whether key was new |
| `update` | `<K, V>(map, hashUtils, key, fn) : Map<K, V>` | Apply `(?V) -> ?V` to existing value |

### Deleting

| Function | Signature | Description |
|----------|-----------|-------------|
| `remove` | `<K, V>(map, hashUtils, key) : Map<K, V>` | Remove key |
| `delete` | `<K, V>(map, hashUtils, key) : (Map<K, V>, Bool)` | Remove + return whether key existed |
| `take` | `<K, V>(map, hashUtils, key) : (Map<K, V>, ?V)` | Remove + return old value |

### Cloning

| Function | Signature | Description |
|----------|-----------|-------------|
| `clone` | `<K, V>(map) : Map<K, V>` | O(1) structural share — free snapshot |

### Iterating

| Function | Signature | Description |
|----------|-----------|-------------|
| `entries` | `<K, V>(map) : Iter<(K, V)>` | All key-value pairs |
| `keys` | `<K, V>(map) : Iter<K>` | All keys |
| `vals` / `values` | `<K, V>(map) : Iter<V>` | All values |
| `forEach` | `<K, V>(map, fn)` | Apply side-effecting function to each pair |
| `collectBatch` | `<K, V>(iter, limit) : [(K, V)]` | Drain up to `limit` entries from an iterator (bounded chunked processing) |

### Transforming

| Function | Signature | Description |
|----------|-----------|-------------|
| `map` | `<K, V1, V2>(map, fn) : Map<K, V2>` | Structural map (no hashUtils needed) |
| `map_` | `<K, V1, V2>(map, hashUtils, fn) : Map<K, V2>` | Rebuild-based map |
| `filter` | `<K, V>(map, hashUtils, fn) : Map<K, V>` | Keep entries matching predicate |
| `mapFilter` / `filterMap` | `<K, V1, V2>(map, hashUtils, fn) : Map<K, V2>` | Map + filter in one pass |

### Folding / searching

| Function | Signature | Description |
|----------|-----------|-------------|
| `foldLeft` | `<K, V, A>(map, base, combine) : A` | Left fold |
| `foldRight` | `<K, V, A>(map, base, combine) : A` | Right fold |
| `all` | `<K, V>(map, pred) : Bool` | True if predicate holds for all |
| `any` | `<K, V>(map, pred) : Bool` | True if predicate holds for any |

### Converting

| Function | Signature | Description |
|----------|-----------|-------------|
| `toArray` | `<K, V>(map) : [(K, V)]` | Collect to array |
| `fromIter` / `toMap` | `<K, V>(iter, hashUtils) : Map<K, V>` | Build from iterator |
| `equal` | `<K, V>(self, other, hashUtils, veq) : Bool` | Structural equality |
| `toText` | `<K, V>(map, keyFmt, valFmt) : Text` | Debug string (capped at 1000 entries) |
| `toTextLimit` | `<K, V>(map, keyFmt, valFmt, limit) : Text` | Debug string with explicit entry cap |

---

## Built-in hash utilities

Ready-made `HashUtils` for common key types:

| Binding | Key type | | Binding | Key type |
|---------|----------|-|---------|----------|
| `nhash` | `Nat` | | `ihash` | `Int` |
| `n8hash` | `Nat8` | | `i8hash` | `Int8` |
| `n16hash` | `Nat16` | | `i16hash` | `Int16` |
| `n32hash` | `Nat32` | | `i32hash` | `Int32` |
| `n64hash` | `Nat64` | | `i64hash` | `Int64` |
| `thash` | `Text` | | `phash` | `Principal` |
| `bhash` | `Blob` | | `lhash` | `Bool` |

### Combinators

```motoko
// Composite keys
let pairHash = CM.combineHash(CM.nhash, CM.thash); // HashUtils<(Nat, Text)>

// Override hash for a single lookup
let fixedHash = CM.useHash(CM.nhash, 42);

// Pre-compute hash
let precomputed = CM.calcHash(CM.nhash, myKey);
```

---

## Benchmarks

Measured with `mops bench --replica pocket-ic` comparing **ChampMap** (CHAMP trie) vs **`mo:core/pure/Map`** (red-black tree). Maps are pre-built; each cell measures *only* the operation (except `build` which constructs from scratch).

### Instructions

|         |  CM 10 |  CM 100 |  CM 1_000 |  CM 10_000 |  CM 100_000 | Core 10 | Core 100 | Core 1_000 | Core 10_000 | Core 100_000 |
| :------ | -----: | ------: | --------: | ---------: | ----------: | ------: | -------: | ---------: | ----------: | -----------: |
| build   | 16_810 | 301_782 | 4_866_867 | 70_050_432 | 892_571_108 |  21_993 |  252_138 |  3_668_875 |  48_896_665 |  614_444_993 |
| get     | 11_854 |  67_104 |   711_390 |  8_038_637 |  93_037_014 |  13_662 |   82_978 |  1_097_791 |  13_959_723 |  171_067_014 |
| replace | 21_677 | 371_711 | 5_171_931 | 76_947_532 | 984_444_182 |  21_622 |  198_740 |  2_727_802 |  34_556_080 |  421_503_075 |
| delete  | 14_827 | 313_178 | 5_145_518 | 73_488_944 | 938_023_910 |  20_660 |  210_178 |  2_952_110 |  39_215_479 |  498_705_967 |
| clone   |  6_056 |   8_001 |     8_658 |      7_372 |       5_840 |   9_573 |   10_625 |     10_082 |       8_384 |        6_419 |
| iterate |  7_760 |  44_250 |   337_697 |  3_013_681 |  32_655_520 |  17_458 |   85_998 |    760_337 |   7_509_348 |   75_013_644 |

### Garbage collection (allocation pressure)

|         |    CM 10 |    CM 100 |   CM 1_000 |  CM 10_000 | CM 100_000 |  Core 10 |  Core 100 | Core 1_000 | Core 10_000 | Core 100_000 |
| :------ | -------: | --------: | ---------: | ---------: | ---------: | -------: | --------: | ---------: | ----------: | -----------: |
| build   | 1.61 KiB | 21.16 KiB | 309.93 KiB |   4.13 MiB |  51.82 MiB |  4.9 KiB | 55.14 KiB | 763.37 KiB |    9.65 MiB |   118.76 MiB |
| get     | 1.04 KiB |  1.27 KiB |   2.73 KiB |  17.26 KiB | 201.09 KiB | 1.75 KiB |  1.61 KiB |   1.32 KiB |    1.04 KiB |        772 B |
| replace | 1.78 KiB | 24.38 KiB | 319.52 KiB |    4.4 MiB |  55.57 MiB | 4.39 KiB | 41.93 KiB | 573.46 KiB |    7.26 MiB |    88.29 MiB |
| delete  | 1.39 KiB | 18.21 KiB |  281.8 KiB |   3.87 MiB |  49.22 MiB | 4.51 KiB | 54.41 KiB | 799.52 KiB |   10.52 MiB |   134.95 MiB |
| clone   | 1.04 KiB |  1.19 KiB |   1.19 KiB |      924 B |      632 B | 1.75 KiB |  1.61 KiB |   1.32 KiB |    1.04 KiB |        772 B |
| iterate | 1.09 KiB |  3.94 KiB |     18 KiB | 158.34 KiB |   1.53 MiB | 2.79 KiB | 11.45 KiB |  99.05 KiB |  977.67 KiB |     9.54 MiB |

### Key takeaways

- **Get** is **19 %** faster at 100 keys, **42 %** at 10K, **46 %** at 100K (hash lookup vs tree traversal).
- **Iterate** is **2× faster** across all sizes — flat arrays and compact nodes are cache-friendly.
- **Clone** is free for both (persistent structure), but ChampMap's literal identity copy is marginally cheaper.
- **Build / replace / delete** use fewer GC bytes at all sizes (CHAMP nodes are smaller than RB-tree nodes).
- **`core/pure/Map`** wins on **build** and **replace** at the instruction level because RB-tree rotations are simpler than CHAMP array copying — a classic space-vs-time trade-off.

### When to use which

| Use case | Recommendation |
|----------|----------------|
| Read-heavy workloads (state lookups) | **ChampMap** — hash-based O(1) beats O(log n) |
| Write-heavy with small maps (< 1K) | Either — difference is negligible |
| Frequent snapshots / rollback | **ChampMap** — O(1) clone, lower GC on mutations |
| Ordered iteration needed | `core/pure/Map` — maintains key order |

### Reproducing

```bash
mops bench --replica pocket-ic
```

---

## Running tests

```bash
# Unit tests (650+ assertions)
$(dfx cache show)/moc -r test/ChampMap.mo $(mops sources)
```

## License

MIT
