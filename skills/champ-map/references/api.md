# ChampMap API Reference

Use this file as a quick lookup when writing code with `import CM "mo:champ-map";`.

## Most-used types

```motoko
type HashUtils<K> = (getHash : (K) -> Nat32, areEqual : (K, K) -> Bool);

type Map<K, V> = {
  #empty;
  #arrayMap : [var (K, V)];
  #trie : Node<K, V>;
};
```

## Most-used functions

```motoko
empty<K, V>() : Map<K, V>
get<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : ?V
has<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : Bool
put<K, V>(map, hashUtils, key, value) : Map<K, V>
swap<K, V>(map, hashUtils, key, value) : (Map<K, V>, ?V)
replace<K, V>(map, hashUtils, key, value) : (Map<K, V>, ?V)
insert<K, V>(map, hashUtils, key, value) : (Map<K, V>, Bool)
update<K, V>(map, hashUtils, key, fn : (?V) -> ?V) : Map<K, V>
remove<K, V>(map, hashUtils, key) : Map<K, V>
delete<K, V>(map, hashUtils, key) : (Map<K, V>, Bool)
take<K, V>(map, hashUtils, key) : (Map<K, V>, ?V)
size<K, V>(map : Map<K, V>) : Nat
clone<K, V>(map : Map<K, V>) : Map<K, V>
```

## Iteration and bulk operations

```motoko
entries<K, V>(map) : Iter<(K, V)>
keys<K, V>(map) : Iter<K>
vals<K, V>(map) : Iter<V>
forEach<K, V>(map, fn : (K, V) -> ())
collectBatch<K, V>(iter : Iter<(K, V)>, limit : Nat) : [(K, V)]
toArray<K, V>(map) : [(K, V)]
fromIter<K, V>(iter : Iter<(K, V)>, hashUtils) : Map<K, V>
```

Use `collectBatch` when the user is processing large maps in a canister.

## Transform functions

```motoko
map<K, V1, V2>(map, fn : (K, V1) -> V2) : Map<K, V2>
map_<K, V1, V2>(map, hashUtils, fn : (K, V1) -> V2) : Map<K, V2>
filter<K, V>(map, hashUtils, fn : (K, V) -> Bool) : Map<K, V>
mapFilter<K, V1, V2>(map, hashUtils, fn : (K, V1) -> ?V2) : Map<K, V2>
```

Use `map` for value-only transforms. Use `map_` only when a rebuild is acceptable.

## Conversion, equality, validation

```motoko
equal<K, V>(self, other, hashUtils, veq : (V, V) -> Bool) : Bool
toText<K, V>(map, keyFmt : K -> Text, valFmt : V -> Text) : Text
toTextLimit<K, V>(map, keyFmt, valFmt, limit : Nat) : Text
validate<K, V>(map, hashUtils) : { #ok; #err : Text }
```

Use `validate()` before trusting a `CM.Map<K, V>` that came from outside the canister.

## Built-in `HashUtils`

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

## Hash combinators

```motoko
combineHash<K1, K2>(hu1 : HashUtils<K1>, hu2 : HashUtils<K2>) : HashUtils<(K1, K2)>
withSeed<K>(seed : Nat32, hashUtils : HashUtils<K>) : HashUtils<K>
useHash<K>(hashUtils : HashUtils<K>, hash : Nat32) : HashUtils<K>
calcHash<K>(hashUtils : HashUtils<K>, key : K) : HashUtils<K>
```

Use `combineHash` for tuple keys. Use `withSeed` for untrusted keys. Do not use `useHash` or `calcHash` as the long-lived hash utils for a map.
