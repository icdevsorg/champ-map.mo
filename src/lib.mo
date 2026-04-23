import Array "mo:core/Array";
import Blob "mo:core/Blob";
import Int8 "mo:core/Int8";
import Int16 "mo:core/Int16";
import Int32 "mo:core/Int32";
import Int64 "mo:core/Int64";
import Iter "mo:core/Iter";
import Nat8 "mo:core/Nat8";
import Nat16 "mo:core/Nat16";
import Nat32 "mo:core/Nat32";
import Nat64 "mo:core/Nat64";
import Principal "mo:core/Principal";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";

module {

  // IC INSTRUCTION BUDGET GUIDANCE
  // The Internet Computer limits each message to ~5 billion instructions.
  // For maps with simple key/value types (Nat, Text, Blob):
  //   - get, put, remove, swap, replace, take: safe at any practical size (O(log n), ~7 levels max)
  //   - entries, forEach, toArray, size: O(n) — safe up to ~200K entries per message
  //   - filter, mapFilter, map_: O(n log n) rebuild — safe up to ~100K entries per message
  //   - equal: O(n log n) — safe up to ~50K entries per message
  //   - toText: O(n²) string concat — capped at 1000 entries by default (use toTextLimit)
  //   - fromIter: O(n log n) — safe up to ~100K entries per message
  // For larger maps, use collectBatch() with entries() to process in bounded chunks.
  // These estimates assume ~50-byte keys/values; larger objects reduce safe limits.

  public type HashUtils<K> = (
    getHash: (K) -> Nat32,
    areEqual: (K, K) -> Bool,
  );

  /// CHAMP (Compressed Hash-Array Mapped Prefix-tree) node.
  /// `#branch(datamap, nodemap, data, children)`:
  ///   datamap  – bitmap of hash slots that hold inline (hash, K, V) entries
  ///   nodemap  – bitmap of hash slots that hold child sub-nodes
  ///   data     – compressed array of inline entries, ordered by popcount
  ///   children – compressed array of child nodes, ordered by popcount
  /// `#collision(hash, entries)` – bucket of entries sharing the same 32-bit hash
  public type Node<K, V> = {
    #branch : (Nat32, Nat32, [var (Nat32, K, V)], [var Node<K, V>]);
    #collision : (Nat32, [var (K, V)]);
  };

  /// Root-level persistent map type.
  /// `#empty`    – zero entries
  /// `#arrayMap` – flat array for ≤ ARRAY_MAX entries (no hashing overhead)
  /// `#trie`     – CHAMP trie (> ARRAY_MAX entries or after promotion)
  public type Map<K, V> = {
    #empty;
    #arrayMap : [var (K, V)];
    #trie : Node<K, V>;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let BITS : Nat32 = 5;
  let MASK : Nat32 = 0x1f;
  let ARRAY_MAX : Nat = 16;

  func bitpos(hash : Nat32, shift : Nat32) : Nat32 {
    (1 : Nat32) << ((hash >> shift) & MASK);
  };

  func index(bitmap : Nat32, bit : Nat32) : Nat {
    Nat32.toNat(Nat32.bitcountNonZero(bitmap & (bit - 1)));
  };

  func popcount8(bitmap : Nat32) : Nat8 {
    Nat8.fromNat(Nat32.toNat(Nat32.bitcountNonZero(bitmap)));
  };

  // Nat8-based array helpers for branch/arrayMap operations (max 32 entries)
  func arrayInsert<T>(arr : [var T], pos : Nat8, elem : T, s8 : Nat8) : [var T] {
    let result = VarArray.repeat<T>(elem, Nat8.toNat(s8) + 1);
    var j : Nat8 = 0;
    while (j < pos) {
      let jn = Nat8.toNat(j);
      result[jn] := arr[jn];
      j +%= 1;
    };
    j := pos;
    while (j < s8) {
      let jn = Nat8.toNat(j);
      result[jn + 1] := arr[jn];
      j +%= 1;
    };
    result;
  };

  func arrayReplace<T>(arr : [var T], pos : Nat8, elem : T, s8 : Nat8) : [var T] {
    let result = VarArray.repeat<T>(elem, Nat8.toNat(s8));
    var j : Nat8 = 0;
    while (j < s8) {
      if (j != pos) {
        let jn = Nat8.toNat(j);
        result[jn] := arr[jn];
      };
      j +%= 1;
    };
    result;
  };

  func arrayRemove<T>(arr : [var T], pos : Nat8, s8 : Nat8) : [var T] {
    let ns8 = s8 -% 1;
    let result = VarArray.repeat<T>(arr[0], Nat8.toNat(ns8));
    var j : Nat8 = 0;
    while (j < pos) {
      let jn = Nat8.toNat(j);
      result[jn] := arr[jn];
      j +%= 1;
    };
    while (j < ns8) {
      let jn = Nat8.toNat(j);
      result[jn] := arr[jn + 1];
      j +%= 1;
    };
    result;
  };

  // Nat-based array helpers for collision buckets (unbounded size)
  func collInsert<T>(arr : [var T], pos : Nat, elem : T, s : Nat) : [var T] {
    let result = VarArray.repeat<T>(elem, s + 1);
    var j : Nat = 0;
    while (j < pos) {
      result[j] := arr[j];
      j += 1;
    };
    j := pos;
    while (j < s) {
      result[j + 1] := arr[j];
      j += 1;
    };
    result;
  };

  func collReplace<T>(arr : [var T], pos : Nat, elem : T, s : Nat) : [var T] {
    let result = VarArray.repeat<T>(elem, s);
    var j : Nat = 0;
    while (j < s) {
      if (j != pos) {
        result[j] := arr[j];
      };
      j += 1;
    };
    result;
  };

  func collRemove<T>(arr : [var T], pos : Nat, s : Nat) : [var T] {
    let ns = s - 1;
    let result = VarArray.repeat<T>(arr[0], ns);
    var j : Nat = 0;
    while (j < pos) {
      result[j] := arr[j];
      j += 1;
    };
    while (j < ns) {
      result[j] := arr[j + 1];
      j += 1;
    };
    result;
  };

  func isEmptyNode<K, V>(node : Node<K, V>) : Bool {
    switch node {
      case (#branch(0, 0, _, _)) true;
      case _ false;
    };
  };

  /// If node is a singleton branch (1 inline entry, 0 children), return that entry.
  func canInline<K, V>(node : Node<K, V>) : ?(Nat32, K, V) {
    switch node {
      case (#branch(_, 0, data, _)) {
        if (data.size() == 1) ?data[0] else null;
      };
      case _ null;
    };
  };

  /// Promote a full arrayMap (ARRAY_MAX entries) + one new entry into a CHAMP trie.
  /// INVARIANT: neverEq is safe here because all entries come from a deduplicated arrayMap
  /// plus one new entry that was already checked for non-membership by the caller.
  func promoteToTrie<K, V>(entries : [var (K, V)], newKey : K, newValue : V, getHash : (K) -> Nat32) : Map<K, V> {
    assert entries.size() == ARRAY_MAX;
    let neverEq = func(_a : K, _b : K) : Bool { false };
    var node : Node<K, V> = #branch(0, 0, [var], [var]);
    var i : Nat8 = 0;
    let s8 : Nat8 = Nat8.fromNat(entries.size());
    while (i < s8) {
      let idx = Nat8.toNat(i);
      let h = getHash(entries[idx].0);
      node := trieInsert<K, V>(node, h, entries[idx].0, entries[idx].1, neverEq, 0);
      i +%= 1;
    };
    let h = getHash(newKey);
    node := trieInsert<K, V>(node, h, newKey, newValue, neverEq, 0);
    #trie(node);
  };

  /// Merge two inline entries into a new sub-trie at the given shift level.
  func mergeEntries<K, V>(h1 : Nat32, k1 : K, v1 : V, h2 : Nat32, k2 : K, v2 : V, shift : Nat32) : Node<K, V> {
    if (shift >= 32) {
      #collision(h1, [var (k1, v1), (k2, v2)]);
    } else {
      let bit1 = bitpos(h1, shift);
      let bit2 = bitpos(h2, shift);
      if (bit1 == bit2) {
        let child = mergeEntries<K, V>(h1, k1, v1, h2, k2, v2, shift + BITS);
        #branch(0, bit1, [var], [var child]);
      } else {
        let combined = bit1 | bit2;
        let idx1 = index(combined, bit1);
        if (idx1 == 0) {
          #branch(combined, 0, [var (h1, k1, v1), (h2, k2, v2)], [var]);
        } else {
          #branch(combined, 0, [var (h2, k2, v2), (h1, k1, v1)], [var]);
        };
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func empty<K, V>() : Map<K, V> { #empty };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func isEmpty<K, V>(map : Map<K, V>) : Bool {
    switch map {
      case (#empty) true;
      case _ false;
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func get<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : ?V {
    switch map {
      case (#empty) null;
      case (#arrayMap(entries)) {
        let eq = hashUtils.1;
        var i : Nat8 = 0;
        let s8 : Nat8 = Nat8.fromNat(entries.size());
        while (i < s8) {
          let idx = Nat8.toNat(i);
          if (eq(entries[idx].0, key)) return ?(entries[idx].1);
          i +%= 1;
        };
        null;
      };
      case (#trie(node)) {
        let hash = hashUtils.0(key);
        getNode<K, V>(node, hash, key, hashUtils.1, 0);
      };
    };
  };

  func getNode<K, V>(node : Node<K, V>, hash : Nat32, key : K, eq : (K, K) -> Bool, shift : Nat32) : ?V {
    var current = node;
    var sh = shift;
    loop {
      switch current {
        case (#branch(datamap, nodemap, data, children)) {
          let bit = bitpos(hash, sh);
          if ((datamap & bit) != 0) {
            let idx = index(datamap, bit);
            let entry = data[idx];
            return if (entry.0 == hash and eq(entry.1, key)) ?(entry.2) else null;
          } else if ((nodemap & bit) != 0) {
            let idx = index(nodemap, bit);
            current := children[idx];
            sh +%= BITS;
          } else {
            return null;
          };
        };
        case (#collision(h, entries)) {
          if (h != hash) return null;
          var i : Nat = 0;
          let s = entries.size();
          while (i < s) {
            if (eq(entries[i].0, key)) return ?(entries[i].1);
            i += 1;
          };
          return null;
        };
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func has<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : Bool {
    switch (get(map, hashUtils, key)) {
      case (?_) true;
      case null false;
    };
  };

  public func containsKey<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : Bool {
    has<K, V>(map, hashUtils, key);
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func put<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K, value : V) : Map<K, V> {
    switch map {
      case (#empty) {
        #arrayMap([var (key, value)]);
      };
      case (#arrayMap(entries)) {
        let eq = hashUtils.1;
        var i : Nat8 = 0;
        let s8 : Nat8 = Nat8.fromNat(entries.size());
        while (i < s8) {
          let idx = Nat8.toNat(i);
          if (eq(entries[idx].0, key)) {
            return #arrayMap(arrayReplace<(K, V)>(entries, i, (key, value), s8));
          };
          i +%= 1;
        };
        if (Nat8.toNat(s8) < ARRAY_MAX) {
          #arrayMap(arrayInsert<(K, V)>(entries, s8, (key, value), s8));
        } else {
          promoteToTrie<K, V>(entries, key, value, hashUtils.0);
        };
      };
      case (#trie(node)) {
        let hash = hashUtils.0(key);
        #trie(trieInsert<K, V>(node, hash, key, value, hashUtils.1, 0));
      };
    };
  };

  func trieInsert<K, V>(node : Node<K, V>, hash : Nat32, key : K, value : V, eq : (K, K) -> Bool, shift : Nat32) : Node<K, V> {
    switch node {
      case (#branch(datamap, nodemap, data, children)) {
        let bit = bitpos(hash, shift);
        let ds8 = popcount8(datamap);
        let ns8 = popcount8(nodemap);
        if ((datamap & bit) != 0) {
          let dIdx = index(datamap, bit);
          let (h, k, _v) = data[dIdx];
          if (h == hash and eq(k, key)) {
            #branch(datamap, nodemap, arrayReplace<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), (h, key, value), ds8), children);
          } else {
            let nIdx = index(nodemap, bit);
            let child = mergeEntries<K, V>(h, k, _v, hash, key, value, shift + BITS);
            #branch(
              datamap ^ bit,
              nodemap | bit,
              arrayRemove<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), ds8),
              arrayInsert<Node<K, V>>(children, Nat8.fromNat(nIdx), child, ns8),
            );
          };
        } else if ((nodemap & bit) != 0) {
          let nIdx = index(nodemap, bit);
          let newChild = trieInsert<K, V>(children[nIdx], hash, key, value, eq, shift + BITS);
          #branch(datamap, nodemap, data, arrayReplace<Node<K, V>>(children, Nat8.fromNat(nIdx), newChild, ns8));
        } else {
          let dIdx = index(datamap | bit, bit);
          #branch(
            datamap | bit,
            nodemap,
            arrayInsert<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), (hash, key, value), ds8),
            children,
          );
        };
      };
      case (#collision(h, entries)) {
        if (h == hash) {
          var i : Nat = 0;
          let s = entries.size();
          while (i < s) {
            if (eq(entries[i].0, key)) {
              return #collision(h, collReplace<(K, V)>(entries, i, (key, value), s));
            };
            i += 1;
          };
          #collision(h, collInsert<(K, V)>(entries, s, (key, value), s));
        } else {
          let bit1 = bitpos(h, shift);
          let bit2 = bitpos(hash, shift);
          if (bit1 == bit2) {
            let child = trieInsert<K, V>(node, hash, key, value, eq, shift + BITS);
            #branch(0, bit1, [var], [var child]);
          } else {
            #branch(bit2, bit1, [var (hash, key, value)], [var node]);
          };
        };
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func add<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K, value : V) : Map<K, V> {
    put<K, V>(map, hashUtils, key, value);
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func singleton<K, V>(_hashUtils : HashUtils<K>, key : K, value : V) : Map<K, V> {
    #arrayMap([var (key, value)]);
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func insert<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K, value : V) : (Map<K, V>, Bool) {
    switch (swap<K, V>(map, hashUtils, key, value)) {
      case (newMap, null) (newMap, true);
      case (newMap, _) (newMap, false);
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func remove<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : Map<K, V> {
    take<K, V>(map, hashUtils, key).0;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func size<K, V>(map : Map<K, V>) : Nat {
    switch map {
      case (#empty) 0;
      case (#arrayMap(entries)) entries.size();
      case (#trie(node)) nodeSize<K, V>(node);
    };
  };

  func nodeSize<K, V>(node : Node<K, V>) : Nat {
    switch node {
      case (#branch(_, _, data, children)) {
        var count = data.size();
        var i : Nat8 = 0;
        let s8 : Nat8 = Nat8.fromNat(children.size());
        while (i < s8) {
          count += nodeSize<K, V>(children[Nat8.toNat(i)]);
          i +%= 1;
        };
        count;
      };
      case (#collision(_, entries)) entries.size();
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func entries<K, V>(map : Map<K, V>) : Iter.Iter<(K, V)> {
    switch map {
      case (#empty) {
        object { public func next() : ?(K, V) { null } };
      };
      case (#arrayMap(es)) {
        var idx : Nat8 = 0;
        let esLen : Nat8 = Nat8.fromNat(es.size());
        object {
          public func next() : ?(K, V) {
            if (idx < esLen) {
              let entry = es[Nat8.toNat(idx)];
              idx +%= 1;
              ?entry;
            } else null;
          };
        };
      };
      case (#trie(node)) {
        nodeEntries<K, V>(node);
      };
    };
  };

  func nodeEntries<K, V>(root : Node<K, V>) : Iter.Iter<(K, V)> {
    let placeholder : Node<K, V> = #branch(0, 0, [var], [var]);
    // DFS pushes all children per node; worst case ~190 (31*6 + 4 across 7 CHAMP levels)
    let stack = VarArray.repeat<Node<K, V>>(placeholder, 192);
    stack[0] := root;
    var sp = 1;
    var dataBuf : [var (Nat32, K, V)] = [var];
    var dataIdx = 0;
    var dataBufLen = 0;
    var collBuf : [var (K, V)] = [var];
    var collIdx = 0;
    var collBufLen = 0;

    object {
      public func next() : ?(K, V) {
        if (dataIdx < dataBufLen) {
          let entry = dataBuf[dataIdx];
          dataIdx += 1;
          return ?(entry.1, entry.2);
        };
        if (collIdx < collBufLen) {
          let entry = collBuf[collIdx];
          collIdx += 1;
          return ?entry;
        };

        label search loop {
          if (sp == 0) return null;
          sp -= 1;
          let node = stack[sp];
          switch node {
            case (#branch(_, _, data, children)) {
              var i = children.size();
              while (i > 0) { i -= 1; stack[sp] := children[i]; sp += 1 };
              if (data.size() > 0) {
                dataBuf := data;
                dataBufLen := data.size();
                dataIdx := 1;
                return ?(data[0].1, data[0].2);
              };
              continue search;
            };
            case (#collision(_, es)) {
              if (es.size() > 0) {
                collBuf := es;
                collBufLen := es.size();
                collIdx := 1;
                return ?(es[0]);
              };
              continue search;
            };
          };
        };

        null;
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func keys<K, V>(map : Map<K, V>) : Iter.Iter<K> {
    Iter.map<(K, V), K>(entries<K, V>(map), func(entry : (K, V)) : K { entry.0 });
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func vals<K, V>(map : Map<K, V>) : Iter.Iter<V> {
    Iter.map<(K, V), V>(entries<K, V>(map), func(entry : (K, V)) : V { entry.1 });
  };

  public func values<K, V>(map : Map<K, V>) : Iter.Iter<V> {
    vals<K, V>(map);
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  /// Collect up to `limit` entries from an iterator into an array.
  /// Returns an empty array when the iterator is exhausted.
  /// Use with `entries()` for batch processing of large maps within IC instruction limits.
  ///
  /// Example:
  /// ```
  /// let iter = ChampMap.entries(map);
  /// let batch1 = ChampMap.collectBatch(iter, 1000);
  /// // ... process batch1 ...
  /// let batch2 = ChampMap.collectBatch(iter, 1000);
  /// // ... when batch returns empty, iteration is complete
  /// ```
  public func collectBatch<K, V>(iter : Iter.Iter<(K, V)>, limit : Nat) : [(K, V)] {
    if (limit == 0) return [];
    switch (iter.next()) {
      case null [];
      case (?first) {
        let buf = VarArray.repeat<(K, V)>(first, limit);
        var i = 1;
        label fill while (i < limit) {
          switch (iter.next()) {
            case (?entry) { buf[i] := entry; i += 1 };
            case null { break fill };
          };
        };
        let count = i;
        Array.tabulate<(K, V)>(count, func(j : Nat) : (K, V) { buf[j] });
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func fromIter<K, V>(iter : Iter.Iter<(K, V)>, hashUtils : HashUtils<K>) : Map<K, V> {
    var map = empty<K, V>();
    for ((k, v) in iter) {
      map := put<K, V>(map, hashUtils, k, v);
    };
    map;
  };

  public func toMap<K, V>(iter : Iter.Iter<(K, V)>, hashUtils : HashUtils<K>) : Map<K, V> {
    fromIter<K, V>(iter, hashUtils);
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func clone<K, V>(map : Map<K, V>) : Map<K, V> { map };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func find<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : ?(K, V) {
    switch (get(map, hashUtils, key)) {
      case (?v) {
        ?(key, v);
      };
      case null null;
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  /// Single-pass insert/update: inserts or updates the key and returns the old value in one traversal.
  /// Matches core/pure/Map `swap` semantics.
  public func swap<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K, value : V) : (Map<K, V>, ?V) {
    switch map {
      case (#empty) {
        (#arrayMap([var (key, value)]), null);
      };
      case (#arrayMap(entries)) {
        let eq = hashUtils.1;
        var i : Nat8 = 0;
        let s8 : Nat8 = Nat8.fromNat(entries.size());
        while (i < s8) {
          let idx = Nat8.toNat(i);
          if (eq(entries[idx].0, key)) {
            let old = entries[idx].1;
            return (#arrayMap(arrayReplace<(K, V)>(entries, i, (key, value), s8)), ?old);
          };
          i +%= 1;
        };
        if (Nat8.toNat(s8) < ARRAY_MAX) {
          (#arrayMap(arrayInsert<(K, V)>(entries, s8, (key, value), s8)), null);
        } else {
          (promoteToTrie<K, V>(entries, key, value, hashUtils.0), null);
        };
      };
      case (#trie(node)) {
        let hash = hashUtils.0(key);
        let (newNode, old) = trieInsertWithOld<K, V>(node, hash, key, value, hashUtils.1, 0);
        (#trie(newNode), old);
      };
    };
  };

  /// Overwrites the value of an existing key. If the key does not exist, returns the original map and null.
  /// Matches core/pure/Map `replace` semantics.
  public func replace<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K, value : V) : (Map<K, V>, ?V) {
    switch map {
      case (#empty) { (map, null) };
      case (#arrayMap(entries)) {
        let eq = hashUtils.1;
        var i : Nat8 = 0;
        let s8 : Nat8 = Nat8.fromNat(entries.size());
        while (i < s8) {
          let idx = Nat8.toNat(i);
          if (eq(entries[idx].0, key)) {
            let old = entries[idx].1;
            return (#arrayMap(arrayReplace<(K, V)>(entries, i, (key, value), s8)), ?old);
          };
          i +%= 1;
        };
        (map, null);
      };
      case (#trie(node)) {
        let hash = hashUtils.0(key);
        switch (trieReplaceOnly<K, V>(node, hash, key, value, hashUtils.1, 0)) {
          case (?(newNode, old)) { (#trie(newNode), ?old) };
          case null { (map, null) };
        };
      };
    };
  };

  func trieReplaceOnly<K, V>(node : Node<K, V>, hash : Nat32, key : K, value : V, eq : (K, K) -> Bool, shift : Nat32) : ?(Node<K, V>, V) {
    switch node {
      case (#branch(datamap, nodemap, data, children)) {
        let bit = bitpos(hash, shift);
        if ((datamap & bit) != 0) {
          let dIdx = index(datamap, bit);
          let (h, k, v) = data[dIdx];
          if (h == hash and eq(k, key)) {
            let ds8 = popcount8(datamap);
            ?(#branch(datamap, nodemap, arrayReplace<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), (h, key, value), ds8), children), v);
          } else { null };
        } else if ((nodemap & bit) != 0) {
          let nIdx = index(nodemap, bit);
          switch (trieReplaceOnly<K, V>(children[nIdx], hash, key, value, eq, shift + BITS)) {
            case (?(newChild, old)) {
              let ns8 = popcount8(nodemap);
              ?(#branch(datamap, nodemap, data, arrayReplace<Node<K, V>>(children, Nat8.fromNat(nIdx), newChild, ns8)), old);
            };
            case null { null };
          };
        } else { null };
      };
      case (#collision(h, entries)) {
        if (h != hash) return null;
        var i : Nat = 0;
        let s = entries.size();
        while (i < s) {
          if (eq(entries[i].0, key)) {
            let old = entries[i].1;
            return ?(#collision(h, collReplace<(K, V)>(entries, i, (key, value), s)), old);
          };
          i += 1;
        };
        null;
      };
    };
  };

  func trieInsertWithOld<K, V>(node : Node<K, V>, hash : Nat32, key : K, value : V, eq : (K, K) -> Bool, shift : Nat32) : (Node<K, V>, ?V) {
    switch node {
      case (#branch(datamap, nodemap, data, children)) {
        let bit = bitpos(hash, shift);
        let ds8 = popcount8(datamap);
        let ns8 = popcount8(nodemap);
        if ((datamap & bit) != 0) {
          let dIdx = index(datamap, bit);
          let (h, k, v) = data[dIdx];
          if (h == hash and eq(k, key)) {
            (#branch(datamap, nodemap, arrayReplace<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), (h, key, value), ds8), children), ?v);
          } else {
            let nIdx = index(nodemap, bit);
            let child = mergeEntries<K, V>(h, k, v, hash, key, value, shift + BITS);
            (#branch(
              datamap ^ bit,
              nodemap | bit,
              arrayRemove<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), ds8),
              arrayInsert<Node<K, V>>(children, Nat8.fromNat(nIdx), child, ns8),
            ), null);
          };
        } else if ((nodemap & bit) != 0) {
          let nIdx = index(nodemap, bit);
          let (newChild, old) = trieInsertWithOld<K, V>(children[nIdx], hash, key, value, eq, shift + BITS);
          (#branch(datamap, nodemap, data, arrayReplace<Node<K, V>>(children, Nat8.fromNat(nIdx), newChild, ns8)), old);
        } else {
          let dIdx = index(datamap | bit, bit);
          (#branch(
            datamap | bit,
            nodemap,
            arrayInsert<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), (hash, key, value), ds8),
            children,
          ), null);
        };
      };
      case (#collision(h, entries)) {
        if (h == hash) {
          var i : Nat = 0;
          let s = entries.size();
          while (i < s) {
            if (eq(entries[i].0, key)) {
              let old = entries[i].1;
              return (#collision(h, collReplace<(K, V)>(entries, i, (key, value), s)), ?old);
            };
            i += 1;
          };
          (#collision(h, collInsert<(K, V)>(entries, s, (key, value), s)), null);
        } else {
          let bit1 = bitpos(h, shift);
          let bit2 = bitpos(hash, shift);
          if (bit1 == bit2) {
            let (child, old) = trieInsertWithOld<K, V>(node, hash, key, value, eq, shift + BITS);
            (#branch(0, bit1, [var], [var child]), old);
          } else {
            (#branch(bit2, bit1, [var (hash, key, value)], [var node]), null);
          };
        };
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func set<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K, value : V) : Map<K, V> {
    put(map, hashUtils, key, value);
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func delete<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : (Map<K, V>, Bool) {
    switch (take<K, V>(map, hashUtils, key)) {
      case (newMap, null) (newMap, false);
      case (newMap, _) (newMap, true);
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func take<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K) : (Map<K, V>, ?V) {
    switch map {
      case (#empty) { (map, null) };
      case (#arrayMap(entries)) {
        let eq = hashUtils.1;
        var i : Nat8 = 0;
        let s8 : Nat8 = Nat8.fromNat(entries.size());
        while (i < s8) {
          let idx = Nat8.toNat(i);
          if (eq(entries[idx].0, key)) {
            let old = entries[idx].1;
            if (Nat8.toNat(s8) == 1) return (#empty, ?old);
            return (#arrayMap(arrayRemove<(K, V)>(entries, i, s8)), ?old);
          };
          i +%= 1;
        };
        (map, null);
      };
      case (#trie(node)) {
        let hash = hashUtils.0(key);
        switch (trieRemoveWithOld<K, V>(node, hash, key, hashUtils.1, 0)) {
          case (?(newNode, old)) {
            let newMap = if (isEmptyNode<K, V>(newNode)) #empty else #trie(newNode);
            (newMap, ?old);
          };
          case null { (map, null) };
        };
      };
    };
  };

  func trieRemoveWithOld<K, V>(node : Node<K, V>, hash : Nat32, key : K, eq : (K, K) -> Bool, shift : Nat32) : ?(Node<K, V>, V) {
    switch node {
      case (#branch(datamap, nodemap, data, children)) {
        let bit = bitpos(hash, shift);
        if ((datamap & bit) != 0) {
          let dIdx = index(datamap, bit);
          let (h, k, v) = data[dIdx];
          if (h == hash and eq(k, key)) {
            let ds8 = popcount8(datamap);
            let ns8 = popcount8(nodemap);
            let newNode = #branch(
              datamap ^ bit,
              nodemap,
              arrayRemove<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), ds8),
              children,
            );
            ?(newNode, v);
          } else { null };
        } else if ((nodemap & bit) != 0) {
          let nIdx = index(nodemap, bit);
          switch (trieRemoveWithOld<K, V>(children[nIdx], hash, key, eq, shift + BITS)) {
            case (?(newChild, old)) {
              let ds8 = popcount8(datamap);
              let ns8 = popcount8(nodemap);
              switch (canInline<K, V>(newChild)) {
                case (?entry) {
                  let dIdx = index(datamap | bit, bit);
                  ?(#branch(
                    datamap | bit,
                    nodemap ^ bit,
                    arrayInsert<(Nat32, K, V)>(data, Nat8.fromNat(dIdx), entry, ds8),
                    arrayRemove<Node<K, V>>(children, Nat8.fromNat(nIdx), ns8),
                  ), old);
                };
                case null {
                  ?(#branch(datamap, nodemap, data, arrayReplace<Node<K, V>>(children, Nat8.fromNat(nIdx), newChild, ns8)), old);
                };
              };
            };
            case null { null };
          };
        } else { null };
      };
      case (#collision(h, entries)) {
        if (h != hash) return null;
        var i : Nat = 0;
        let s = entries.size();
        while (i < s) {
          if (eq(entries[i].0, key)) {
            let old = entries[i].1;
            if (s == 1) {
              return ?(#branch(0, 0, [var], [var]), old);
            };
            return ?(#collision(h, collRemove<(K, V)>(entries, i, s)), old);
          };
          i += 1;
        };
        null;
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func update<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, key : K, fn : (?V) -> ?V) : Map<K, V> {
    let old = get(map, hashUtils, key);
    switch (fn(old)) {
      case (?v) put(map, hashUtils, key, v);
      case null {
        switch old {
          case (?_) remove(map, hashUtils, key);
          case null map;
        };
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  /// Converts the map to an immutable array of (key, value) pairs.
  /// Allocates a single array of exact size (no buffer doubling).
  /// For large maps that may exceed IC instruction limits, use `collectBatch` with `entries()` instead.
  public func toArray<K, V>(map : Map<K, V>) : [(K, V)] {
    let n = size<K, V>(map);
    if (n == 0) return [];
    let iter = entries<K, V>(map);
    Array.tabulate<(K, V)>(n, func(_i : Nat) : (K, V) {
      switch (iter.next()) {
        case (?v) v;
        case null loop {};
      };
    });
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func forEach<K, V>(map : Map<K, V>, fn : (K, V) -> ()) {
    for ((k, v) in entries<K, V>(map)) {
      fn(k, v);
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func map_<K, V1, V2>(map : Map<K, V1>, hashUtils : HashUtils<K>, fn : (K, V1) -> V2) : Map<K, V2> {
    var result = empty<K, V2>();
    for ((k, v) in entries<K, V1>(map)) {
      result := put<K, V2>(result, hashUtils, k, fn(k, v));
    };
    result;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  /// Structural map: transforms values in-place without rebuilding the CHAMP trie.
  /// No hashUtils required since the tree structure depends only on key hashes.
  /// Matches core/pure/Map `map` signature (no compare needed).
  public func map<K, V1, V2>(map_ : Map<K, V1>, fn : (K, V1) -> V2) : Map<K, V2> {
    switch map_ {
      case (#empty) #empty;
      case (#arrayMap(entries)) {
        let s = entries.size();
        let mapped = VarArray.repeat<(K, V2)>(entries[0] |> (_.0, fn(_.0, _.1)), s);
        var i = 1;
        while (i < s) {
          mapped[i] := (entries[i].0, fn(entries[i].0, entries[i].1));
          i += 1;
        };
        #arrayMap(mapped);
      };
      case (#trie(node)) {
        #trie(mapNode<K, V1, V2>(node, fn));
      };
    };
  };

  func mapNode<K, V1, V2>(node : Node<K, V1>, fn : (K, V1) -> V2) : Node<K, V2> {
    switch node {
      case (#branch(datamap, nodemap, data, children)) {
        let ds = data.size();
        let ns = children.size();
        let newData = if (ds > 0) {
          let d = VarArray.repeat<(Nat32, K, V2)>((data[0].0, data[0].1, fn(data[0].1, data[0].2)), ds);
          var i = 1;
          while (i < ds) {
            d[i] := (data[i].0, data[i].1, fn(data[i].1, data[i].2));
            i += 1;
          };
          d;
        } else {
          [var] : [var (Nat32, K, V2)];
        };
        let newChildren = if (ns > 0) {
          let c = VarArray.repeat<Node<K, V2>>(mapNode<K, V1, V2>(children[0], fn), ns);
          var i = 1;
          while (i < ns) {
            c[i] := mapNode<K, V1, V2>(children[i], fn);
            i += 1;
          };
          c;
        } else {
          [var] : [var Node<K, V2>];
        };
        #branch(datamap, nodemap, newData, newChildren);
      };
      case (#collision(h, entries)) {
        let s = entries.size();
        let mapped = VarArray.repeat<(K, V2)>((entries[0].0, fn(entries[0].0, entries[0].1)), s);
        var i = 1;
        while (i < s) {
          mapped[i] := (entries[i].0, fn(entries[i].0, entries[i].1));
          i += 1;
        };
        #collision(h, mapped);
      };
    };
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func filter<K, V>(map : Map<K, V>, hashUtils : HashUtils<K>, fn : (K, V) -> Bool) : Map<K, V> {
    var result = empty<K, V>();
    for ((k, v) in entries<K, V>(map)) {
      if (fn(k, v)) {
        result := put<K, V>(result, hashUtils, k, v);
      };
    };
    result;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func mapFilter<K, V1, V2>(map : Map<K, V1>, hashUtils : HashUtils<K>, fn : (K, V1) -> ?V2) : Map<K, V2> {
    var result = empty<K, V2>();
    for ((k, v) in entries<K, V1>(map)) {
      switch (fn(k, v)) {
        case (?v2) { result := put<K, V2>(result, hashUtils, k, v2) };
        case null {};
      };
    };
    result;
  };

  public func filterMap<K, V1, V2>(map : Map<K, V1>, hashUtils : HashUtils<K>, fn : (K, V1) -> ?V2) : Map<K, V2> {
    mapFilter<K, V1, V2>(map, hashUtils, fn);
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func foldLeft<K, V, A>(map : Map<K, V>, base : A, combine : (A, K, V) -> A) : A {
    var acc = base;
    for ((k, v) in entries<K, V>(map)) {
      acc := combine(acc, k, v);
    };
    acc;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func foldRight<K, V, A>(map : Map<K, V>, base : A, combine : (K, V, A) -> A) : A {
    var acc = base;
    for ((k, v) in entries<K, V>(map)) {
      acc := combine(k, v, acc);
    };
    acc;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func all<K, V>(map : Map<K, V>, pred : (K, V) -> Bool) : Bool {
    for ((k, v) in entries<K, V>(map)) {
      if (not pred(k, v)) return false;
    };
    true;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  public func any<K, V>(map : Map<K, V>, pred : (K, V) -> Bool) : Bool {
    for ((k, v) in entries<K, V>(map)) {
      if (pred(k, v)) return true;
    };
    false;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  /// WARNING: Performs 2× O(n) size traversals + O(n log n) entry lookups.
  /// For maps with >50K entries this may exceed IC instruction limits.
  /// Not used internally — consider whether you need full equality
  /// or can compare a subset via `collectBatch`.
  public func equal<K, V>(self : Map<K, V>, other : Map<K, V>, hashUtils : HashUtils<K>, veq : (V, V) -> Bool) : Bool {
    if (size<K, V>(self) != size<K, V>(other)) return false;
    for ((k, v) in entries<K, V>(self)) {
      switch (get<K, V>(other, hashUtils, k)) {
        case (?v2) { if (not veq(v, v2)) return false };
        case null { return false };
      };
    };
    true;
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  /// Renders the map as text with a default cap of 1000 entries.
  /// Uses O(n²) string concatenation — for large maps, use `toTextLimit` with a small limit
  /// or iterate with `collectBatch` and build text externally.
  public func toText<K, V>(map : Map<K, V>, keyFormat : K -> Text, valueFormat : V -> Text) : Text {
    toTextLimit<K, V>(map, keyFormat, valueFormat, 1000);
  };

  /// Renders the map as text, displaying at most `limit` entries.
  /// Remaining entries are indicated with "...".
  public func toTextLimit<K, V>(map : Map<K, V>, keyFormat : K -> Text, valueFormat : V -> Text, limit : Nat) : Text {
    var first = true;
    var parts = "ChampMap{";
    var count = 0;
    label render for ((k, v) in entries<K, V>(map)) {
      if (count >= limit) {
        parts #= ", ...";
        break render;
      };
      if (not first) { parts #= ", " } else { first := false };
      parts #= "(" # keyFormat(k) # ", " # valueFormat(v) # ")";
      count += 1;
    };
    parts # "}";
  };

  //////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  // Hash utility functions

  public func hashInt(key: Int): Nat32 {
    var hash = Nat64.fromIntWrap(key);
    hash := hash >> 30 ^ hash *% 0xbf58476d1ce4e5b9;
    hash := hash >> 27 ^ hash *% 0x94d049bb133111eb;
    hash := hash >> 31 ^ hash;
    Nat64.toNat32(hash & 0xFFFFFFFF);
  };

  public func hashInt8(key: Int8): Nat32 {
    var hash = Nat16.toNat32(Nat8.toNat16(Int8.toNat8(key)));
    hash := hash >> 16 ^ hash *% 0x21f0aaad;
    hash := hash >> 15 ^ hash *% 0x735a2d97;
    hash >> 15 ^ hash;
  };

  public func hashInt16(key: Int16): Nat32 {
    var hash = Nat16.toNat32(Int16.toNat16(key));
    hash := hash >> 16 ^ hash *% 0x21f0aaad;
    hash := hash >> 15 ^ hash *% 0x735a2d97;
    hash >> 15 ^ hash;
  };

  public func hashInt32(key: Int32): Nat32 {
    var hash = Int32.toNat32(key);
    hash := hash >> 16 ^ hash *% 0x21f0aaad;
    hash := hash >> 15 ^ hash *% 0x735a2d97;
    hash >> 15 ^ hash;
  };

  public func hashInt64(key: Int64): Nat32 {
    var hash = Int64.toNat64(key);
    hash := hash >> 30 ^ hash *% 0xbf58476d1ce4e5b9;
    hash := hash >> 27 ^ hash *% 0x94d049bb133111eb;
    hash := hash >> 31 ^ hash;
    Nat64.toNat32(hash & 0xFFFFFFFF);
  };

  public func hashNat(key: Nat): Nat32 {
    var hash = Nat64.fromIntWrap(key);
    hash := hash >> 30 ^ hash *% 0xbf58476d1ce4e5b9;
    hash := hash >> 27 ^ hash *% 0x94d049bb133111eb;
    hash := hash >> 31 ^ hash;
    Nat64.toNat32(hash & 0xFFFFFFFF);
  };

  public func hashNat8(key: Nat8): Nat32 {
    var hash = Nat16.toNat32(Nat8.toNat16(key));
    hash := hash >> 16 ^ hash *% 0x21f0aaad;
    hash := hash >> 15 ^ hash *% 0x735a2d97;
    hash >> 15 ^ hash;
  };

  public func hashNat16(key: Nat16): Nat32 {
    var hash = Nat16.toNat32(key);
    hash := hash >> 16 ^ hash *% 0x21f0aaad;
    hash := hash >> 15 ^ hash *% 0x735a2d97;
    hash >> 15 ^ hash;
  };

  public func hashNat32(key: Nat32): Nat32 {
    var hash = key;
    hash := hash >> 16 ^ hash *% 0x21f0aaad;
    hash := hash >> 15 ^ hash *% 0x735a2d97;
    hash >> 15 ^ hash;
  };

  public func hashNat64(key: Nat64): Nat32 {
    var hash = key;
    hash := hash >> 30 ^ hash *% 0xbf58476d1ce4e5b9;
    hash := hash >> 27 ^ hash *% 0x94d049bb133111eb;
    hash := hash >> 31 ^ hash;
    Nat64.toNat32(hash & 0xFFFFFFFF);
  };

  public func hashText(key: Text): Nat32 {
    Blob.hash(Text.encodeUtf8(key));
  };

  public func hashPrincipal(key: Principal): Nat32 {
    Blob.hash(Principal.toBlob(key));
  };

  public func hashBlob(key: Blob): Nat32 {
    Blob.hash(key);
  };

  public func hashBool(key: Bool): Nat32 {
    if (key) 114489971 else 0;
  };

  public let ihash = (hashInt, func(a, b) = a == b):HashUtils<Int>;
  public let i8hash = (hashInt8, func(a, b) = a == b):HashUtils<Int8>;
  public let i16hash = (hashInt16, func(a, b) = a == b):HashUtils<Int16>;
  public let i32hash = (hashInt32, func(a, b) = a == b):HashUtils<Int32>;
  public let i64hash = (hashInt64, func(a, b) = a == b):HashUtils<Int64>;

  public let nhash = (hashNat, func(a, b) = a == b):HashUtils<Nat>;
  public let n8hash = (hashNat8, func(a, b) = a == b):HashUtils<Nat8>;
  public let n16hash = (hashNat16, func(a, b) = a == b):HashUtils<Nat16>;
  public let n32hash = (hashNat32, func(a, b) = a == b):HashUtils<Nat32>;
  public let n64hash = (hashNat64, func(a, b) = a == b):HashUtils<Nat64>;

  public let thash = (hashText, func(a, b) = a == b):HashUtils<Text>;
  public let phash = (hashPrincipal, func(a, b) = a == b):HashUtils<Principal>;
  public let bhash = (hashBlob, func(a, b) = a == b):HashUtils<Blob>;
  public let lhash = (hashBool, func(a, b) = a == b):HashUtils<Bool>;

  public func combineHash<K1, K2>(hashUtils1: HashUtils<K1>, hashUtils2: HashUtils<K2>): HashUtils<(K1, K2)> {
    let getHash1 = hashUtils1.0;
    let getHash2 = hashUtils2.0;
    let areEqual1 = hashUtils1.1;
    let areEqual2 = hashUtils2.1;
    (
      func(key) = (getHash1(key.0) +% getHash2(key.1)),
      func(a, b) = areEqual1(a.0, b.0) and areEqual2(a.1, b.1),
    )
  };

  public func useHash<K>(hashUtils: HashUtils<K>, hash: Nat32): HashUtils<K> {
    (func(_key) = hash, hashUtils.1);
  };

  public func calcHash<K>(hashUtils: HashUtils<K>, key: K): HashUtils<K> {
    let hash = hashUtils.0(key);
    (func(_key) = hash, hashUtils.1);
  };

};
