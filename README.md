# ChampMap

A **persistent / functional API** for hash maps in [Motoko](https://internetcomputer.org/docs/current/motoko/main/about-this-guide), built on the **CHAMP** (Compressed Hash-Array Mapped Prefix-tree) data structure.

Persistence/immutability guarantees apply when the map is used through ChampMap's public functions such as `empty`, `put`, `get`, `remove`, `swap`, `entries`, and `clone`. The exported `Map<K, V>` representation is currently structural and contains mutable arrays internally, so callers should treat it as an opaque value and should not construct, destructure, or mutate raw map values directly.

## Funded by ICDevs.org

This library was funded by ICDevs.org - a 501c3 non-profit. If you use it in production, please consider making a donation at https://g53ex-oqaaa-aaaab-ae5ua-cai.icp0.io/#/mint or https://icdevs.org/donation.html.

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
| **Persistent / immutable when used via API** | Every mutation returns a *new* map; the old version is unchanged when you use ChampMap's public functions and treat `Map<K, V>` as opaque. |
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

Use the public functions and treat `Map<K, V>` values as opaque snapshots. Do not pattern-match on `#arrayMap` / `#trie` or mutate the backing arrays directly.

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

`Map<K, V>` is shown below so the API surface is explicit, but normal consumers should treat it as a raw/internal representation detail and should not construct or mutate it directly.

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
| `validate` | `<K, V>(map, hashUtils) : {#ok; #err : Text}` | Verify structural invariants — use at trust boundaries (see [Security considerations](#security-considerations)) |

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
// Composite keys (uses an xxHash-style mixer — see Security considerations)
let pairHash = CM.combineHash(CM.nhash, CM.thash); // HashUtils<(Nat, Text)>

// Per-instance seeded hashing — defeats hash-flooding when keys come from
// untrusted callers. Use one fresh seed per map.
let seeded = CM.withSeed<Nat>(myRandomSeed, CM.nhash);

// UNSAFE: returns a HashUtils whose getHash always returns the given value.
// Only valid for batched operations on one specific key whose hash you have
// already computed. NEVER use as a general HashUtils — every key would land
// in one bucket.
let fixedHash = CM.useHash(CM.nhash, 42);
let precomputed = CM.calcHash(CM.nhash, myKey);
```

---

## Security considerations

ChampMap is **not safe by default against adversarial keys**. If your keys come from untrusted callers (principals, user-supplied text, opaque blobs from a public method, composite keys involving any of the above), an attacker who knows the hash function can pre-compute keys that all collide into a single bucket. Lookups against a polluted map degrade from `O(1)` to `O(N)` and a single fat bucket can blow the IC's per-message instruction budget. This applies to every hash map, not just this one.

### Threats and mitigations

| Threat | Mitigation |
|--------|------------|
| **Hash-flooding** — attacker submits keys with the same `Nat32` hash, forcing all entries into one `#collision` bucket. | Wrap your `HashUtils` with `withSeed<K>(seed, hashUtils)` and pick a fresh per-instance `seed` (canister-local randomness, secret nonce, etc.) so the attacker cannot pre-compute collisions. Honest workloads pay nothing. |
| **Composite-key collisions via `combineHash`** — the previous `+%` combiner allowed `(a,b)` and `(b,a)` to share a hash trivially. | Already fixed: `combineHash` uses an xxHash-style mixer (multiply‐rotate‐multiply‐xor). Combine with `withSeed` if either component is attacker-controlled. |
| **Malformed or directly-mutated `Map<K, V>` shape** — because `Map<K, V>` is a public structural type, a candid caller can synthesise a `#arrayMap` with > 16 entries, duplicate keys, or a `#branch` whose bitmaps disagree with its arrays, and in-process code can also violate persistence guarantees by mutating raw `[var]` arrays after destructuring. Such values can misbehave or trap on subsequent operations. | **Treat `Map<K, V>` as opaque and never accept or mutate it directly across a trust boundary.** Round-trip via `[(K, V)]` + `fromIter`. If you must accept it, call `validate(map, hashUtils)` first and reject `#err`. |
| **`useHash` / `calcHash` misuse** — these helpers return a `HashUtils` whose `getHash` ignores its key argument. Threading one into a general put/get path collapses every key into one bucket. | These are intended only for short, batched operations where the caller has already computed the hash for one specific key. Never store one as the canonical `HashUtils` for a map. |
| **Unbounded mass operations** — `fromIter`, `forEach`, `filter`, `mapFilter`, `map_`, `equal` iterate without a cycle ceiling. Untrusted iterators can blow the per-message instruction budget. | Use `entries` + `collectBatch` to chunk processing. The header comment in `lib.mo` documents safe size estimates per operation. |

### Recommended pattern at trust boundaries

```motoko
// Accept entries as a flat array, NOT as a Map<K, V> shape.
public func ingest(entries : [(Principal, Nat)]) : async () {
  let seeded = CM.withSeed<Principal>(perCanisterSeed, CM.phash);
  let m = CM.fromIter<Principal, Nat>(entries.vals(), seeded);
  // ... store m, persist seed alongside it ...
};
```

If you absolutely must accept a `Map<K, V>` directly:

```motoko
public func acceptMap(m : CM.Map<Principal, Nat>) : async {#ok; #err : Text} {
  switch (CM.validate<Principal, Nat>(m, CM.phash)) {
    case (#ok)       { /* ... safe to use ... */ #ok };
    case (#err msg)  { #err msg };
  };
};
```

---

## Benchmarks

Measured with `mops bench --replica pocket-ic`.

- `bench/champ.bench.mo` compares **ChampMap** (CHAMP trie), **`mo:hamt/pure/HashMap`**, and **`mo:core/pure/Map`** on `Nat` keys.
- `bench/key_types.bench.mo` compares **ChampMap** and **`mo:hamt/pure/HashMap`** on `Text` and `Blob` keys.
- Maps are pre-built; each cell measures *only* the operation, except `build`.

### Nat keys: instructions

|         |  CM 10 |  CM 16 |  CM 100 |  CM 1_000 |  CM 10_000 |  CM 100_000 | HAMT 10 | HAMT 16 | HAMT 100 | HAMT 1_000 | HAMT 10_000 |  HAMT 100_000 | Core 10 | Core 16 | Core 100 | Core 1_000 | Core 10_000 | Core 100_000 |
| :------ | -----: | -----: | ------: | --------: | ---------: | ----------: | ------: | ------: | -------: | ---------: | ----------: | ------------: | ------: | ------: | -------: | ---------: | ----------: | -----------: |
| build   | 20_141 | 34_452 | 305_582 | 4_894_162 | 70_280_392 | 895_007_469 |  35_526 |  54_502 |  551_466 |  8_706_450 | 125_208_922 | 1_569_449_661 |  25_727 |  36_845 |  253_224 |  3_669_920 |  48_897_464 |  614_445_464 |
| get     | 15_185 | 22_578 |  70_010 |   729_195 |  8_194_105 |  94_538_295 |  25_129 |  32_737 |  161_081 |  1_726_014 |  19_974_409 |   213_567_590 |  17_396 |  20_352 |   84_064 |  1_098_877 |  13_960_809 |  171_068_100 |
| replace | 25_008 | 46_123 | 375_543 | 5_198_307 | 77_183_573 | 986_745_810 |  42_992 |  69_322 |  776_179 | 10_069_447 | 147_874_471 | 1_718_983_405 |  25_356 |  33_704 |  199_785 |  2_728_970 |  34_557_125 |  421_503_259 |
| delete  | 19_066 | 30_194 | 325_552 | 5_279_579 | 75_056_403 | 955_608_135 |  39_288 |  59_747 |  564_434 |  9_160_049 | 130_545_278 | 1_628_971_192 |  24_394 |  33_155 |  211_264 |  2_953_196 |  39_215_991 |  498_707_709 |
| clone   |  9_387 |  9_175 |   9_084 |     9_741 |      8_455 |       6_923 |  13_691 |  13_479 |   12_095 |     11_552 |       9_854 |         7_889 |  13_307 |  13_095 |   11_711 |     11_168 |       9_470 |        7_505 |
| iterate | 11_091 | 11_683 |  44_437 |   337_843 |  3_013_868 |  32_654_710 |  25_387 |  32_618 |  153_538 |  1_263_021 |  14_311_550 |   127_609_045 |  21_192 |  25_533 |   87_043 |    761_423 |   7_510_393 |   75_014_689 |

### Nat keys: garbage collection

|         |    CM 10 |    CM 16 |    CM 100 |   CM 1_000 |  CM 10_000 | CM 100_000 |  HAMT 10 |  HAMT 16 |  HAMT 100 | HAMT 1_000 | HAMT 10_000 | HAMT 100_000 |  Core 10 |  Core 16 |  Core 100 | Core 1_000 | Core 10_000 | Core 100_000 |
| :------ | -------: | -------: | --------: | ---------: | ---------: | ---------: | -------: | -------: | --------: | ---------: | ----------: | -----------: | -------: | -------: | --------: | ---------: | ----------: | -----------: |
| build   | 2.18 KiB | 2.57 KiB | 22.45 KiB | 319.89 KiB |   4.22 MiB |   52.7 MiB | 4.88 KiB | 6.61 KiB | 43.75 KiB | 610.26 KiB |    7.85 MiB |    95.04 MiB | 5.47 KiB |    8 KiB | 55.42 KiB | 763.66 KiB |    9.65 MiB |   118.76 MiB |
| get     | 1.61 KiB | 1.47 KiB |  2.44 KiB |  11.36 KiB |  96.06 KiB | 984.48 KiB | 2.96 KiB | 3.34 KiB | 11.87 KiB | 117.34 KiB |    1.32 MiB |    14.14 MiB | 2.32 KiB | 2.18 KiB |  1.89 KiB |   1.61 KiB |    1.32 KiB |     1.04 KiB |
| replace | 2.35 KiB | 3.04 KiB |    26 KiB | 332.32 KiB |   4.52 MiB |  56.72 MiB | 5.38 KiB | 7.67 KiB | 58.68 KiB | 705.27 KiB |    9.28 MiB |   105.18 MiB | 4.96 KiB |  6.8 KiB | 42.21 KiB | 573.75 KiB |    7.26 MiB |    88.29 MiB |
| delete  | 2.12 KiB | 2.48 KiB |  23.1 KiB | 336.67 KiB |   4.52 MiB |  56.58 MiB | 4.77 KiB | 6.47 KiB | 43.17 KiB | 633.54 KiB |    8.21 MiB |   100.69 MiB | 5.08 KiB | 7.21 KiB |  54.7 KiB |  799.8 KiB |   10.52 MiB |   134.95 MiB |
| clone   | 1.61 KiB | 1.47 KiB |  1.47 KiB |   1.47 KiB |   1.19 KiB |      924 B | 2.18 KiB | 2.04 KiB |  1.76 KiB |   1.47 KiB |    1.19 KiB |        924 B | 2.32 KiB | 2.18 KiB |  1.89 KiB |   1.61 KiB |    1.32 KiB |     1.04 KiB |
| iterate | 1.66 KiB | 1.52 KiB |  3.97 KiB |  18.04 KiB | 158.38 KiB |   1.53 MiB | 2.98 KiB | 3.26 KiB |  9.43 KiB |  71.63 KiB |  760.94 KiB |     6.92 MiB | 3.36 KiB | 3.81 KiB | 11.73 KiB |  99.34 KiB |  977.96 KiB |     9.54 MiB |

### Text and Blob keys: instruction checkpoints

To keep the README readable, the full `Text`/`Blob` benchmark matrix is summarized at the fast-path boundary (`16`) and at scale (`100_000`). The raw full table is emitted by `bench/key_types.bench.mo`.

|         | CM/Text 16 | HAMT/Text 16 | CM/Text 100_000 | HAMT/Text 100_000 | CM/Blob 16 | HAMT/Blob 16 | CM/Blob 100_000 | HAMT/Blob 100_000 |
| :------ | ---------: | -----------: | --------------: | ----------------: | ---------: | -----------: | --------------: | ----------------: |
| build   |     90_398 |      104_501 |     945_380_520 |     1_697_594_205 |     74_795 |      104_107 |     909_562_716 |     1_660_895_318 |
| get     |     82_166 |       90_534 |     203_734_395 |       394_605_334 |     65_317 |       88_894 |     138_880_954 |       328_852_010 |
| replace |    105_679 |      126_495 |   1_066_883_571 |     1_899_755_436 |     88_830 |      124_855 |   1_002_030_335 |     1_834_003_629 |
| delete  |     66_625 |      114_927 |   1_039_892_322 |     1_810_466_593 |     65_391 |      113_287 |     975_040_275 |     1_744_713_433 |
| clone   |     41_916 |       51_773 |          42_590 |            50_983 |     41_928 |       51_779 |          42_602 |            50_989 |
| iterate |     44_430 |       72_570 |      29_836_181 |       129_675_591 |     44_442 |       72_576 |      29_836_193 |       129_675_597 |

### Text and Blob keys: GC checkpoints

|         | CM/Text 16 | HAMT/Text 16 | CM/Text 100_000 | HAMT/Text 100_000 | CM/Blob 16 | HAMT/Blob 16 | CM/Blob 100_000 | HAMT/Blob 100_000 |
| :------ | ---------: | -----------: | --------------: | ----------------: | ---------: | -----------: | --------------: | ----------------: |
| build   |    6.8 KiB |    11.32 KiB |       53.78 MiB |         96.79 MiB |    6.8 KiB |    11.32 KiB |       52.06 MiB |         95.07 MiB |
| get     |    5.7 KiB |     8.18 KiB |        2.67 MiB |         15.87 MiB |    5.7 KiB |     8.18 KiB |       979.2 KiB |         14.15 MiB |
| replace |   7.27 KiB |    12.59 KiB |       56.81 MiB |          106.9 MiB |   7.27 KiB |    12.59 KiB |        55.1 MiB |        105.19 MiB |
| delete  |   6.71 KiB |    11.19 KiB |       57.16 MiB |        102.44 MiB |   6.71 KiB |    11.19 KiB |       55.44 MiB |        100.72 MiB |
| clone   |    5.7 KiB |     6.64 KiB |        5.73 KiB |          6.67 KiB |    5.7 KiB |     6.64 KiB |        5.73 KiB |          6.67 KiB |
| iterate |   5.75 KiB |      7.9 KiB |        1.53 MiB |          6.92 MiB |   5.75 KiB |      7.9 KiB |        1.53 MiB |          6.92 MiB |

### Key takeaways

- **The `16`-entry fast path is visible.** At 16 `Nat` keys, ChampMap beats HAMT on every operation and also beats `core/pure/Map` on `build`, `delete`, `clone`, and `iterate`; `core/pure/Map` still edges it on `get` and `replace`.
- **ChampMap consistently beats `hamt/pure/HashMap` in this harness.** That holds for `Nat`, `Text`, and `Blob` keys, at both small and large sizes, on instructions and GC.
- **Read-heavy and iteration-heavy workloads still favor ChampMap.** At 100K `Nat` keys, `get` is ~1.83× faster than HAMT and ~1.81× faster than `core/pure/Map`, while `iterate` is ~3.9× faster than HAMT and ~2.3× faster than `core/pure/Map`.
- **Text and Blob keys amplify the gap versus HAMT.** At 100K keys, ChampMap iteration is ~4.35× faster for `Text` and ~4.35× faster for `Blob`; GC on `get` is dramatically lower as well.
- **`core/pure/Map` still has the cheapest writes among the persistent structures.** On `Nat` keys it wins `build` and `replace` at the instruction level, but pays for that with ordered-tree traversal and higher mutation GC than ChampMap at scale.

### When to use which

| Use case | Recommendation |
|----------|----------------|
| Read-heavy workloads (state lookups) | **ChampMap** — it wins across `Nat`, `Text`, and `Blob` lookups in this harness |
| Small hot maps around the fast-path cutoff | **ChampMap** — the `16`-entry array fast path is visible in the measurements |
| Frequent snapshots / rollback | **ChampMap** — O(1) clone and lower mutation GC than HAMT |
| Ordered iteration needed | `core/pure/Map` — maintains key order |
| Cheapest persistent write path on `Nat` keys | `core/pure/Map` — lower `build`/`replace` instructions than the hash maps |

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

## AI coding-agent skill

This repo includes an AI coding-agent skill at `skills/champ-map/SKILL.md`. Point your agent at that file to help it write correct ChampMap code in your project.

## License

MIT
