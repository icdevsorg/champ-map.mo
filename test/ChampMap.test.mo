import CM "../src/lib";
import Nat "mo:core/Nat";
import Debug "mo:core/Debug";

do {
  let { nhash; thash } = CM;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Empty map
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let m0 = CM.empty<Nat, Text>();
  assert CM.size(m0) == 0;
  assert CM.get(m0, nhash, 0) == null;
  assert CM.has(m0, nhash, 0) == false;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Single entry
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let m1 = CM.put(m0, nhash, 42, "hello");
  assert CM.size(m1) == 1;
  assert CM.get(m1, nhash, 42) == ?"hello";
  assert CM.has(m1, nhash, 42) == true;
  assert CM.get(m1, nhash, 0) == null;

  // Original unchanged (structural sharing)
  assert CM.size(m0) == 0;
  assert CM.get(m0, nhash, 42) == null;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Replace value
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let m2 = CM.put(m1, nhash, 42, "world");
  assert CM.get(m2, nhash, 42) == ?"world";
  assert CM.get(m1, nhash, 42) == ?"hello"; // original unchanged

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Multiple entries
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  var m = CM.empty<Nat, Text>();
  for (i in Nat.rangeInclusive(0, 99)) {
    m := CM.put(m, nhash, i, Nat.toText(i));
  };
  assert CM.size(m) == 100;
  for (i in Nat.rangeInclusive(0, 99)) {
    assert CM.get(m, nhash, i) == ?Nat.toText(i);
  };
  assert CM.get(m, nhash, 100) == null;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Remove
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let m3 = CM.remove(m1, nhash, 42);
  assert CM.size(m3) == 0;
  assert CM.get(m3, nhash, 42) == null;
  assert CM.get(m1, nhash, 42) == ?"hello"; // original unchanged

  // Remove nonexistent key
  let m4 = CM.remove(m1, nhash, 999);
  assert CM.size(m4) == 1;
  assert CM.get(m4, nhash, 42) == ?"hello";

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Remove from large map
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  var mDel = m;
  for (i in Nat.rangeInclusive(0, 49)) {
    mDel := CM.remove(mDel, nhash, i);
  };
  assert CM.size(mDel) == 50;
  for (i in Nat.rangeInclusive(0, 49)) {
    assert CM.get(mDel, nhash, i) == null;
  };
  for (i in Nat.rangeInclusive(50, 99)) {
    assert CM.get(mDel, nhash, i) == ?Nat.toText(i);
  };
  // Original still has all 100
  assert CM.size(m) == 100;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Iterator
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let m5 = CM.fromIter<Nat, Text>([(1, "a"), (2, "b"), (3, "c")].vals(), nhash);
  assert CM.size(m5) == 3;

  var iterCount = 0;
  var iterSum = 0;
  for ((k, v) in CM.entries(m5)) {
    iterCount += 1;
    iterSum += k;
  };
  assert iterCount == 3;
  assert iterSum == 6;

  // Keys iterator
  var keySum = 0;
  for (k in CM.keys(m5)) {
    keySum += k;
  };
  assert keySum == 6;

  // Vals iterator
  var valCount = 0;
  for (v in CM.vals(m5)) {
    valCount += 1;
  };
  assert valCount == 3;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Large scale - 10_000 entries
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  var bigMap = CM.empty<Nat, Nat>();
  for (i in Nat.rangeInclusive(0, 9_999)) {
    bigMap := CM.put(bigMap, nhash, i, i * 2);
  };
  assert CM.size(bigMap) == 10_000;

  // Verify all entries
  for (i in Nat.rangeInclusive(0, 9_999)) {
    assert CM.get(bigMap, nhash, i) == ?(i * 2);
  };

  // Delete half
  var halfMap = bigMap;
  for (i in Nat.rangeInclusive(0, 4_999)) {
    halfMap := CM.remove(halfMap, nhash, i);
  };
  assert CM.size(halfMap) == 5_000;
  for (i in Nat.rangeInclusive(5_000, 9_999)) {
    assert CM.get(halfMap, nhash, i) == ?(i * 2);
  };

  // Original untouched
  assert CM.size(bigMap) == 10_000;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Clone is identity (O(1) structural sharing)
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let original = CM.fromIter<Nat, Text>([(1, "x"), (2, "y")].vals(), nhash);
  let cloned = CM.clone(original);
  assert CM.get(cloned, nhash, 1) == ?"x";
  assert CM.get(cloned, nhash, 2) == ?"y";

  // Mutating cloned path doesn't affect original
  let modified = CM.put(cloned, nhash, 1, "modified");
  assert CM.get(modified, nhash, 1) == ?"modified";
  assert CM.get(original, nhash, 1) == ?"x";
  assert CM.get(cloned, nhash, 1) == ?"x";

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Text keys
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  var textMap = CM.empty<Text, Nat>();
  textMap := CM.put(textMap, thash, "hello", 1);
  textMap := CM.put(textMap, thash, "world", 2);
  textMap := CM.put(textMap, thash, "foo", 3);
  assert CM.get(textMap, thash, "hello") == ?1;
  assert CM.get(textMap, thash, "world") == ?2;
  assert CM.get(textMap, thash, "foo") == ?3;
  assert CM.get(textMap, thash, "bar") == null;
  assert CM.size(textMap) == 3;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // swap: insert/update + return old value
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let (m6, old1) = CM.swap(m1, nhash, 42, "replaced");
  assert old1 == ?"hello";
  assert CM.get(m6, nhash, 42) == ?"replaced";

  let (m7, old2) = CM.swap(m1, nhash, 999, "new");
  assert old2 == null;
  assert CM.get(m7, nhash, 999) == ?"new";

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // replace: only overwrites existing, no-op if absent
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let (m6r, old1r) = CM.replace(m1, nhash, 42, "replaced");
  assert old1r == ?"hello";
  assert CM.get(m6r, nhash, 42) == ?"replaced";

  let (m7r, old2r) = CM.replace(m1, nhash, 999, "new");
  assert old2r == null;
  assert CM.get(m7r, nhash, 999) == null; // replace does NOT insert

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // find
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  assert CM.find(m1, nhash, 42) == ?(42, "hello");
  assert CM.find(m1, nhash, 999) == null;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // set and delete (aliases)
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let m8 = CM.set(m0, nhash, 10, "ten");
  assert CM.get(m8, nhash, 10) == ?"ten";
  let (m9, wasPresent9) = CM.delete(m8, nhash, 10);
  assert CM.get(m9, nhash, 10) == null;
  assert wasPresent9 == true;
  let (m9b, wasPresent9b) = CM.delete(m8, nhash, 999);
  assert wasPresent9b == false;
  assert CM.size(m9b) == 1;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // update
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let m10 = CM.fromIter<Nat, Nat>([(1, 10), (2, 20)].vals(), nhash);

  // Update existing key
  let m11 = CM.update(m10, nhash, 1, func(old : ?Nat) : ?Nat {
    switch old { case (?v) ?(v + 5); case null ?0 };
  });
  assert CM.get(m11, nhash, 1) == ?15;

  // Update nonexistent key (insert)
  let m12 = CM.update(m10, nhash, 3, func(old : ?Nat) : ?Nat {
    switch old { case (?v) ?(v + 5); case null ?99 };
  });
  assert CM.get(m12, nhash, 3) == ?99;

  // Update to null (remove)
  let m13 = CM.update(m10, nhash, 1, func(_old : ?Nat) : ?Nat { null });
  assert CM.get(m13, nhash, 1) == null;
  assert CM.size(m13) == 1;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // toArray
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let arr = CM.toArray(m5);
  assert arr.size() == 3;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // forEach
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  var forEachSum = 0;
  CM.forEach<Nat, Text>(m5, func(k : Nat, _v : Text) { forEachSum += k });
  assert forEachSum == 6;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // map
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let mapped = CM.map_<Nat, Nat, Nat>(m10, nhash, func(_k : Nat, v : Nat) : Nat { v * 2 });
  assert CM.get(mapped, nhash, 1) == ?20;
  assert CM.get(mapped, nhash, 2) == ?40;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // filter
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let filtered = CM.filter<Nat, Nat>(m10, nhash, func(_k : Nat, v : Nat) : Bool { v > 10 });
  assert CM.size(filtered) == 1;
  assert CM.get(filtered, nhash, 2) == ?20;
  assert CM.get(filtered, nhash, 1) == null;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // mapFilter
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let mapFiltered = CM.mapFilter<Nat, Nat, Text>(m10, nhash, func(_k : Nat, v : Nat) : ?Text {
    if (v > 10) ?Nat.toText(v) else null;
  });
  assert CM.size(mapFiltered) == 1;
  assert CM.get(mapFiltered, nhash, 2) == ?"20";

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Collision resistance - keys that would share hash prefixes
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  // Use a hash function that forces collisions for testing
  let collisionHash : CM.HashUtils<Nat> = (
    func(_n : Nat) : Nat32 { 42 },  // all keys hash to the same value
    func(a : Nat, b : Nat) : Bool { a == b },
  );

  var collisionMap = CM.empty<Nat, Text>();
  collisionMap := CM.put(collisionMap, collisionHash, 1, "one");
  collisionMap := CM.put(collisionMap, collisionHash, 2, "two");
  collisionMap := CM.put(collisionMap, collisionHash, 3, "three");
  assert CM.size(collisionMap) == 3;
  assert CM.get(collisionMap, collisionHash, 1) == ?"one";
  assert CM.get(collisionMap, collisionHash, 2) == ?"two";
  assert CM.get(collisionMap, collisionHash, 3) == ?"three";

  // Replace in collision bucket
  collisionMap := CM.put(collisionMap, collisionHash, 2, "TWO");
  assert CM.get(collisionMap, collisionHash, 2) == ?"TWO";
  assert CM.size(collisionMap) == 3;

  // Remove from collision bucket
  collisionMap := CM.remove(collisionMap, collisionHash, 2);
  assert CM.size(collisionMap) == 2;
  assert CM.get(collisionMap, collisionHash, 2) == null;
  assert CM.get(collisionMap, collisionHash, 1) == ?"one";
  assert CM.get(collisionMap, collisionHash, 3) == ?"three";

  // Remove until only 1 left (should become leaf)
  collisionMap := CM.remove(collisionMap, collisionHash, 3);
  assert CM.size(collisionMap) == 1;
  assert CM.get(collisionMap, collisionHash, 1) == ?"one";

  // Remove last
  collisionMap := CM.remove(collisionMap, collisionHash, 1);
  assert CM.size(collisionMap) == 0;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Iterator on large map verifies all entries reachable
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  var iterBigCount = 0;
  var iterBigSum = 0;
  for ((k, v) in CM.entries(bigMap)) {
    iterBigCount += 1;
    iterBigSum += k;
  };
  assert iterBigCount == 10_000;
  assert iterBigSum == 49_995_000; // sum 0..9999

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // arrayMap tier - maps with <= 16 entries stay flat
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  // 1) Inserting 1-16 entries should remain in arrayMap tier (no hashing needed for get)
  var smallMap = CM.empty<Nat, Text>();
  for (i in Nat.rangeInclusive(1, 16)) {
    smallMap := CM.put(smallMap, nhash, i, Nat.toText(i));
  };
  assert CM.size(smallMap) == 16;
  for (i in Nat.rangeInclusive(1, 16)) {
    assert CM.get(smallMap, nhash, i) == ?Nat.toText(i);
  };

  // 2) Replace within arrayMap tier
  smallMap := CM.put(smallMap, nhash, 8, "EIGHT");
  assert CM.get(smallMap, nhash, 8) == ?"EIGHT";
  assert CM.size(smallMap) == 16;

  // 3) Remove from arrayMap tier
  let smallRemoved = CM.remove(smallMap, nhash, 5);
  assert CM.size(smallRemoved) == 15;
  assert CM.get(smallRemoved, nhash, 5) == null;
  assert CM.get(smallRemoved, nhash, 6) == ?Nat.toText(6);

  // 4) Remove all from arrayMap
  var shrinking = smallRemoved;
  for (i in Nat.rangeInclusive(1, 16)) {
    shrinking := CM.remove(shrinking, nhash, i);
  };
  assert CM.size(shrinking) == 0;

  // 5) Promotion boundary: 17th entry triggers promotion to trie
  var promotionMap = CM.empty<Nat, Text>();
  for (i in Nat.rangeInclusive(1, 17)) {
    promotionMap := CM.put(promotionMap, nhash, i, Nat.toText(i));
  };
  assert CM.size(promotionMap) == 17;
  // All entries still accessible after promotion
  for (i in Nat.rangeInclusive(1, 17)) {
    assert CM.get(promotionMap, nhash, i) == ?Nat.toText(i);
  };

  // 6) Iterator works on arrayMap
  let smallIter = CM.fromIter<Nat, Nat>([(1, 10), (2, 20), (3, 30)].vals(), nhash);
  var smallIterSum = 0;
  for ((k, v) in CM.entries(smallIter)) {
    smallIterSum += v;
  };
  assert smallIterSum == 60;

  // 7) Clone identity works on arrayMap
  let cloneSmall = CM.clone(smallIter);
  let mutatedSmall = CM.put(cloneSmall, nhash, 1, 999);
  assert CM.get(mutatedSmall, nhash, 1) == ?999;
  assert CM.get(smallIter, nhash, 1) == ?10; // original unchanged

  // 8) toArray on arrayMap
  let smallArr = CM.toArray(smallIter);
  assert smallArr.size() == 3;

  // 9) forEach on arrayMap
  var forEachSmallSum = 0;
  CM.forEach<Nat, Nat>(smallIter, func(_k : Nat, v : Nat) { forEachSmallSum += v });
  assert forEachSmallSum == 60;

  // 10) Remove nonexistent from arrayMap does not change map
  let noChange = CM.remove(smallIter, nhash, 999);
  assert CM.size(noChange) == 3;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Negative / edge-case tests
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  // -- get/has/remove/find/delete on empty map
  assert CM.get<Nat, Nat>(CM.empty(), nhash, 0) == null;
  assert CM.has<Nat, Nat>(CM.empty(), nhash, 0) == false;
  assert CM.size(CM.remove<Nat, Nat>(CM.empty(), nhash, 0)) == 0;
  assert CM.find<Nat, Nat>(CM.empty(), nhash, 0) == null;
  assert CM.size(CM.delete<Nat, Nat>(CM.empty(), nhash, 0).0) == 0;

  // -- replace on empty is no-op (key not found)
  let (repEmpty, repOld) = CM.replace<Nat, Nat>(CM.empty(), nhash, 42, 99);
  assert repOld == null;
  assert CM.get(repEmpty, nhash, 42) == null;

  // -- swap on empty inserts
  let (swapEmpty, swapOld) = CM.swap<Nat, Nat>(CM.empty(), nhash, 42, 99);
  assert swapOld == null;
  assert CM.get(swapEmpty, nhash, 42) == ?99;

  // -- update on empty with null return stays empty
  let upEmpty = CM.update<Nat, Nat>(CM.empty(), nhash, 5, func(_old : ?Nat) : ?Nat { null });
  assert CM.size(upEmpty) == 0;

  // -- double remove is harmless
  let dblRm1 = CM.put<Nat, Text>(CM.empty(), nhash, 1, "a");
  let dblRm2 = CM.remove(dblRm1, nhash, 1);
  let dblRm3 = CM.remove(dblRm2, nhash, 1);
  assert CM.size(dblRm3) == 0;

  // -- overwrite same key many times, only last value sticks
  var overwriteMap = CM.empty<Nat, Nat>();
  for (i in Nat.rangeInclusive(0, 99)) {
    overwriteMap := CM.put(overwriteMap, nhash, 0, i);
  };
  assert CM.size(overwriteMap) == 1;
  assert CM.get(overwriteMap, nhash, 0) == ?99;

  // -- large key values (Nat max-ish)
  let largeKeyMap = CM.put<Nat, Text>(CM.empty(), nhash, 4_294_967_295, "max32");
  assert CM.get(largeKeyMap, nhash, 4_294_967_295) == ?"max32";
  assert CM.get(largeKeyMap, nhash, 0) == null;

  // -- entries iterator on empty map yields nothing
  var emptyIterCount = 0;
  for (_e in CM.entries<Nat, Nat>(CM.empty())) {
    emptyIterCount += 1;
  };
  assert emptyIterCount == 0;

  // -- keys/vals on empty
  var emptyKeysCount = 0;
  for (_k in CM.keys<Nat, Nat>(CM.empty())) { emptyKeysCount += 1 };
  assert emptyKeysCount == 0;

  var emptyValsCount = 0;
  for (_v in CM.vals<Nat, Nat>(CM.empty())) { emptyValsCount += 1 };
  assert emptyValsCount == 0;

  // -- toArray on empty
  assert CM.toArray<Nat, Nat>(CM.empty()).size() == 0;

  // -- fromIter with empty iterator
  let fromEmpty = CM.fromIter<Nat, Nat>(([] : [(Nat, Nat)]).vals(), nhash);
  assert CM.size(fromEmpty) == 0;

  // -- fromIter with duplicate keys, last wins
  let fromDups = CM.fromIter<Nat, Text>([(1, "a"), (2, "b"), (1, "c")].vals(), nhash);
  assert CM.size(fromDups) == 2;
  assert CM.get(fromDups, nhash, 1) == ?"c";

  // -- filter on empty
  let filteredEmpty = CM.filter<Nat, Nat>(CM.empty(), nhash, func(_k : Nat, _v : Nat) : Bool { true });
  assert CM.size(filteredEmpty) == 0;

  // -- filter removes everything
  let allFiltered = CM.filter<Nat, Nat>(m10, nhash, func(_k : Nat, _v : Nat) : Bool { false });
  assert CM.size(allFiltered) == 0;

  // -- map_ on empty
  let mappedEmpty = CM.map_<Nat, Nat, Text>(CM.empty(), nhash, func(_k : Nat, _v : Nat) : Text { "x" });
  assert CM.size(mappedEmpty) == 0;

  // -- mapFilter removes everything
  let mapFilteredNone = CM.mapFilter<Nat, Nat, Text>(m10, nhash, func(_k : Nat, _v : Nat) : ?Text { null });
  assert CM.size(mapFilteredNone) == 0;

  // -- forEach on empty does nothing (no crash)
  CM.forEach<Nat, Nat>(CM.empty(), func(_k : Nat, _v : Nat) {});

  // -- clone of empty
  let clonedEmpty = CM.clone<Nat, Nat>(CM.empty());
  assert CM.size(clonedEmpty) == 0;

  // -- structural sharing: mutation of one version at arrayMap tier
  var share1 = CM.put<Nat, Nat>(CM.empty(), nhash, 1, 10);
  share1 := CM.put(share1, nhash, 2, 20);
  let share2 = CM.put(share1, nhash, 3, 30);
  // share1 should still have only 2 entries
  assert CM.size(share1) == 2;
  assert CM.get(share1, nhash, 3) == null;
  assert CM.size(share2) == 3;
  assert CM.get(share2, nhash, 3) == ?30;

  // -- collision: remove nonexistent key from collision bucket
  var colEdge = CM.empty<Nat, Text>();
  colEdge := CM.put(colEdge, collisionHash, 1, "a");
  colEdge := CM.put(colEdge, collisionHash, 2, "b");
  // After promotion + collision, removing a key not in the bucket is a no-op
  let colEdge2 = CM.remove(colEdge, collisionHash, 999);
  assert CM.size(colEdge2) == 2;

  // -- collision: iterator covers all collision entries
  var colEdge3 = CM.empty<Nat, Text>();
  for (i in Nat.rangeInclusive(1, 5)) {
    colEdge3 := CM.put(colEdge3, collisionHash, i, Nat.toText(i));
  };
  var colIterCount = 0;
  for (_e in CM.entries(colEdge3)) { colIterCount += 1 };
  assert colIterCount == 5;

  // -- rapid grow/shrink cycle preserves integrity
  var churnMap = CM.empty<Nat, Nat>();
  for (cycle in Nat.rangeInclusive(0, 4)) {
    // grow
    for (i in Nat.rangeInclusive(0, 49)) {
      churnMap := CM.put(churnMap, nhash, cycle * 50 + i, i);
    };
    // shrink
    for (i in Nat.rangeInclusive(0, 24)) {
      churnMap := CM.remove(churnMap, nhash, cycle * 50 + i);
    };
  };
  // 5 cycles x 25 remaining per cycle = 125
  assert CM.size(churnMap) == 125;
  for (cycle in Nat.rangeInclusive(0, 4)) {
    for (i in Nat.rangeInclusive(25, 49)) {
      assert CM.get(churnMap, nhash, cycle * 50 + i) == ?i;
    };
  };

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // New API functions
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  // isEmpty
  assert CM.isEmpty<Nat, Nat>(CM.empty()) == true;
  assert CM.isEmpty(m1) == false;

  // containsKey (alias for has)
  assert CM.containsKey(m1, nhash, 42) == true;
  assert CM.containsKey(m1, nhash, 999) == false;

  // add (alias for put)
  let addMap = CM.add<Nat, Text>(CM.empty(), nhash, 1, "one");
  assert CM.get(addMap, nhash, 1) == ?"one";

  // singleton
  let singleMap = CM.singleton<Nat, Text>(nhash, 1, "solo");
  assert CM.size(singleMap) == 1;
  assert CM.get(singleMap, nhash, 1) == ?"solo";

  // insert: returns (map, isNew)
  let (ins1, isNew1) = CM.insert<Nat, Text>(CM.empty(), nhash, 1, "one");
  assert isNew1 == true;
  assert CM.get(ins1, nhash, 1) == ?"one";
  let (ins2, isNew2) = CM.insert<Nat, Text>(ins1, nhash, 1, "ONE");
  assert isNew2 == false;
  assert CM.get(ins2, nhash, 1) == ?"ONE";

  // take: remove + return old value
  let (took1, oldTook1) = CM.take(m1, nhash, 42);
  assert oldTook1 == ?"hello";
  assert CM.get(took1, nhash, 42) == null;
  let (took2, oldTook2) = CM.take<Nat, Text>(m1, nhash, 999);
  assert oldTook2 == null;
  assert CM.size(took2) == 1;

  // values (alias for vals)
  var valuesSum = 0;
  for (v in CM.values(m10)) {
    valuesSum += v;
  };
  assert valuesSum == 30;

  // toMap (alias for fromIter)
  let tmMap = CM.toMap<Nat, Text>([(5, "five")].vals(), nhash);
  assert CM.get(tmMap, nhash, 5) == ?"five";

  // structural map (no hashUtils)
  let structMapped = CM.map<Nat, Nat, Nat>(m10, func(_k : Nat, v : Nat) : Nat { v * 3 });
  assert CM.get(structMapped, nhash, 1) == ?30;
  assert CM.get(structMapped, nhash, 2) == ?60;
  assert CM.size(structMapped) == 2;

  // structural map on empty
  let emptyMapped = CM.map<Nat, Nat, Text>(CM.empty(), func(_k : Nat, _v : Nat) : Text { "x" });
  assert CM.isEmpty(emptyMapped);

  // structural map on large map
  let largeMapped = CM.map<Nat, Nat, Nat>(bigMap, func(_k : Nat, v : Nat) : Nat { v + 1 });
  assert CM.size(largeMapped) == 10_000;
  assert CM.get(largeMapped, nhash, 0) == ?1;
  assert CM.get(largeMapped, nhash, 9_999) == ?19_999;

  // filterMap (alias for mapFilter)
  let fm = CM.filterMap<Nat, Nat, Text>(m10, nhash, func(_k : Nat, v : Nat) : ?Text {
    if (v > 10) ?Nat.toText(v) else null;
  });
  assert CM.size(fm) == 1;
  assert CM.get(fm, nhash, 2) == ?"20";

  // foldLeft
  let sum = CM.foldLeft<Nat, Nat, Nat>(m10, 0, func(acc : Nat, _k : Nat, v : Nat) : Nat { acc + v });
  assert sum == 30;

  // foldRight
  let sumR = CM.foldRight<Nat, Nat, Nat>(m10, 0, func(_k : Nat, v : Nat, acc : Nat) : Nat { acc + v });
  assert sumR == 30;

  // all
  assert CM.all<Nat, Nat>(m10, func(_k : Nat, v : Nat) : Bool { v > 0 }) == true;
  assert CM.all<Nat, Nat>(m10, func(_k : Nat, v : Nat) : Bool { v > 15 }) == false;
  assert CM.all<Nat, Nat>(CM.empty(), func(_k : Nat, _v : Nat) : Bool { false }) == true; // vacuous truth

  // any
  assert CM.any<Nat, Nat>(m10, func(_k : Nat, v : Nat) : Bool { v == 20 }) == true;
  assert CM.any<Nat, Nat>(m10, func(_k : Nat, v : Nat) : Bool { v > 100 }) == false;
  assert CM.any<Nat, Nat>(CM.empty(), func(_k : Nat, _v : Nat) : Bool { true }) == false; // empty

  // equal
  let eq1 = CM.fromIter<Nat, Nat>([(1, 10), (2, 20)].vals(), nhash);
  let eq2 = CM.fromIter<Nat, Nat>([(2, 20), (1, 10)].vals(), nhash);
  let eq3 = CM.fromIter<Nat, Nat>([(1, 10), (2, 99)].vals(), nhash);
  let eq4 = CM.fromIter<Nat, Nat>([(1, 10)].vals(), nhash);
  assert CM.equal<Nat, Nat>(eq1, eq2, nhash, func(a : Nat, b : Nat) : Bool { a == b });
  assert not CM.equal<Nat, Nat>(eq1, eq3, nhash, func(a : Nat, b : Nat) : Bool { a == b });
  assert not CM.equal<Nat, Nat>(eq1, eq4, nhash, func(a : Nat, b : Nat) : Bool { a == b });
  assert CM.equal<Nat, Nat>(CM.empty(), CM.empty(), nhash, func(a : Nat, b : Nat) : Bool { a == b });

  // toText
  let txtMap = CM.fromIter<Nat, Text>([(1, "one")].vals(), nhash);
  let txt = CM.toText<Nat, Text>(txtMap, Nat.toText, func(t : Text) : Text { t });
  // Just verify it produces non-empty text with the expected wrapper
  assert txt.size() > 0;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  Debug.print("All ChampMap tests passed");
};
