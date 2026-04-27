# Introducing ChampMap — a persistent hash map for Motoko that scales past the 4M wall

Hi everyone,

We just published **`champ-map`** to mops — a new persistent / functional hash map for Motoko, built on the **CHAMP** (Compressed Hash-Array Mapped Prefix-tree) data structure. It is a drop-in option whenever you want hash-based `O(1)` lookups in stable canister state without giving up cheap snapshots or running into the rehash cliff that bites large maps today.

The library was funded by **ICDevs.org** (a 501c3 non-profit). If you find it useful in production, please consider chipping in at <https://icdevs.org/donation.html> or minting at <https://g53ex-oqaaa-aaaab-ae5ua-cai.icp0.io/#/mint>.

```
mops add champ-map
```

Repo / docs: <https://github.com/icdevsorg/champ-map.mo>

---

## Why we built it

Most Motoko canisters that need a hash map reach for [`ZhenyaUsenko/motoko-hash-map`](https://github.com/ZhenyaUsenko/motoko-hash-map), and for years it has been the right answer. But v9 — the current line — **tops out around 4 million records** and then can no longer grow within the IC's per-message instruction budget. The next insert after that wall triggers a global rehash/resize step whose cost scales with the whole map, blows the budget, and traps the canister. There is no graceful recovery beyond offloading entries to another canister.

We hit this in production on a token-style workload that genuinely needed tens of millions of records in a single canister, and the only structural fix is to remove the global rehash step entirely.

CHAMP does exactly that. It is a hash trie that consumes 5 bits of hash per level, so it is **at most 7 levels deep regardless of size**, and every insert/delete path-copies only the nodes from the root to one leaf. There is no resize event — per-message cost stays flat as the map grows from thousands to tens of millions of entries.

There is one trade-off worth flagging up front: **ChampMap does not preserve insertion order**. `mo:map` threads a doubly-linked list through its buckets and can be used as a FIFO queue; ChampMap cannot. Iteration order is determined by the trie shape and is stable for a given key set, but it is not insertion order and not key order. If you need either, keep using `mo:map` (insertion) or `mo:core/pure/Map` (key order), or maintain a separate index alongside ChampMap.

## Why it's faster than `mo:core/pure/Map`

`mo:core/pure/Map` is a balanced red-black tree, so every lookup walks `O(log n)` levels — already 17 hops at 100K entries and 20 at 1M. ChampMap's trie is fixed-depth, so every lookup touches at most ~7 nodes no matter how big the map gets. There is no rebalancing, the per-node layout is two compressed arrays indexed by a popcount bitmap (cache-friendly), and maps with ≤ 16 entries skip hashing entirely and use a flat array.

Concretely, measured with `mops bench --replica pocket-ic`:

| Op | 100K entries | ChampMap vs `mo:core/pure/Map` |
|---|---|---|
| `get` | hash lookup vs tree walk | **~46% fewer instructions** |
| `iterate` | flat arrays vs tree traversal | **~2× faster across all sizes** |
| `clone` | structural identity copy | **`O(1)` — free snapshots** |
| `build` / `replace` | path-copy with array splices | uses fewer GC bytes; loses on raw instructions to RB-tree rotations (classic space-vs-time trade) |

So: read-heavy workloads, snapshot-heavy workloads, and workloads that need to scale past the rehash cliff are the sweet spot. Write-heavy small maps are basically a wash.

## How it handles hash collisions

Hashes are `Nat32`, so true 32-bit collisions are possible. Once the trie has consumed all 32 bits and two distinct keys still collide, ChampMap drops in a `#collision(hash, entries)` node — a flat bucket scanned linearly using the user-supplied `areEqual`. The bucket collapses back to an inline trie entry as soon as it shrinks to one element. For well-distributed hashes (the built-in `HashUtils` for `Nat`, `Text`, `Blob`, `Principal`, etc. all qualify), collision buckets are vanishingly rare and never grow beyond a couple of entries. They exist only to make correctness independent of hash quality.

## Quick start

```motoko
import CM "mo:champ-map";

let { nhash } = CM;            // HashUtils<Nat>

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

Built-in `HashUtils` are provided for `Nat`, `Nat8`–`Nat64`, `Int`, `Int8`–`Int64`, `Text`, `Blob`, `Principal`, and `Bool`, plus a `combineHash` combinator for composite keys. The full API mirrors what you'd expect from a modern Motoko collection: `get` / `has` / `find`, `put` / `swap` / `replace` / `update`, `remove` / `delete`, `entries` / `keys` / `vals` / `forEach`, `map` / `filter` / `mapFilter`, `foldLeft` / `foldRight` / `all` / `any`, `fromIter` / `toArray` / `equal`. There is also a `collectBatch` helper for safely chunking iteration when you might brush up against a per-message instruction limit.

## Security considerations (please read this section)

ChampMap is **not safe by default against adversarial keys**. If your keys come from untrusted callers — principals, user-supplied text, opaque blobs from a public method, composite keys involving any of the above — an attacker who knows the hash function can pre-compute keys that all collide into one bucket. Lookups against a polluted map degrade from `O(1)` to `O(N)`, and a single fat bucket can blow the per-message budget. This applies to every hash map, not just this one — but we'd rather call it out loudly than have it bite somebody.

Two mitigations that ship in the library:

1. **`withSeed<K>(seed, hashUtils)`** — wraps any `HashUtils` with a per-instance seed (canister-local randomness, secret nonce, etc.) so an attacker cannot pre-compute collisions. Honest workloads pay nothing.
   ```motoko
   let seeded = CM.withSeed<Principal>(perCanisterSeed, CM.phash);
   var balances = CM.empty<Principal, Nat>();
   balances := CM.put(balances, seeded, caller, amount);
   ```
2. **`validate<K, V>(map, hashUtils) : {#ok; #err : Text}`** — verifies all structural invariants of a `Map<K, V>` value. Because `Map<K, V>` is a public structural type, a candid caller could in principle synthesise a malformed `#arrayMap` with > 16 entries or a `#branch` whose bitmaps disagree with its arrays. **Never accept `Map<K, V>` directly across a trust boundary** — round-trip through `[(K, V)]` + `fromIter`, or call `validate` first and reject `#err`.

`combineHash` was also rewritten to use a real xxHash-style mixer so `(a, b)` and `(b, a)` no longer share a hash trivially. The previous `+%`-based combiner was a footgun for composite keys with attacker-controlled components.

## What's next

Right now `champ-map` is `mops add champ-map` away. If you try it and have feedback — API gaps, benchmarks on your workload, security concerns we haven't thought of — please open an issue on the repo or reply here. We'd especially like to hear from teams that are sitting near the 4M wall today and would consider migrating.

Thanks again to ICDevs.org for funding the work.
