import CM "../src/lib";
import Nat "mo:core/Nat";
import Nat32 "mo:core/Nat32";
import Debug "mo:core/Debug";
import Runtime "mo:core/Runtime";

do {
  let { nhash; thash; n32hash } = CM;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // combineHash mixing — different argument orders / pairs must not collide
  // trivially. This catches the legacy `+%` combiner where (h1(a)+h2(b)) ==
  // (h1(a')+h2(b')) is easy to engineer.
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let combined = CM.combineHash<Nat, Nat>(nhash, nhash);

  // (a, b) and (b, a) must hash differently for nontrivial pairs.
  // Under the old `+%` combiner these collided unconditionally.
  let h_ab = combined.0((1, 2));
  let h_ba = combined.0((2, 1));
  assert h_ab != h_ba;

  // (a, b) and (a', b') with the same component-sum produce different combined
  // hashes (broken under `+%`: h(0)+h(3) == h(1)+h(2) is possible by design).
  // We assert the four pairs (0,3),(1,2),(2,1),(3,0) are mutually distinct.
  let combos = [(0, 3), (1, 2), (2, 1), (3, 0)];
  let h0 = combined.0(combos[0]);
  let h1 = combined.0(combos[1]);
  let h2 = combined.0(combos[2]);
  let h3 = combined.0(combos[3]);
  assert h0 != h1;
  assert h0 != h2;
  assert h0 != h3;
  assert h1 != h2;
  assert h1 != h3;
  assert h2 != h3;

  // areEqual is preserved
  assert combined.1((5, 7), (5, 7));
  assert not combined.1((5, 7), (5, 8));
  assert not combined.1((5, 7), (6, 7));

  // Composite-key map round-trips correctly through put/get
  var pm = CM.empty<(Nat, Nat), Text>();
  pm := CM.put(pm, combined, (1, 2), "a");
  pm := CM.put(pm, combined, (2, 1), "b");
  pm := CM.put(pm, combined, (10, 20), "c");
  assert CM.get(pm, combined, (1, 2)) == ?"a";
  assert CM.get(pm, combined, (2, 1)) == ?"b";
  assert CM.get(pm, combined, (10, 20)) == ?"c";
  assert CM.get(pm, combined, (1, 3)) == null;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // withSeed — different seeds yield different hashes for the same key, while
  // equality semantics are unchanged.
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let seedA = CM.withSeed<Nat>(0xdeadbeef, nhash);
  let seedB = CM.withSeed<Nat>(0xfeedface, nhash);

  // Different seeds → different hashes for the same key (with overwhelming
  // probability for a few sample keys; collision here would mean a bug in
  // the mixer rather than mathematical bad luck).
  var sawDifference = false;
  var k = 0;
  while (k < 32) {
    if (seedA.0(k) != seedB.0(k)) sawDifference := true;
    k += 1;
  };
  assert sawDifference;

  // Equality fn preserved
  assert seedA.1(7, 7);
  assert not seedA.1(7, 8);

  // A seeded map must round-trip independently of an unseeded map. Building
  // the same key set under two different seeds yields two valid maps that
  // each answer queries correctly under their own HashUtils.
  var seededA = CM.empty<Nat, Nat>();
  var seededB = CM.empty<Nat, Nat>();
  var i = 0;
  while (i < 200) {
    seededA := CM.put(seededA, seedA, i, i * 10);
    seededB := CM.put(seededB, seedB, i, i * 10);
    i += 1;
  };
  assert CM.size(seededA) == 200;
  assert CM.size(seededB) == 200;
  i := 0;
  while (i < 200) {
    assert CM.get(seededA, seedA, i) == ?(i * 10);
    assert CM.get(seededB, seedB, i) == ?(i * 10);
    i += 1;
  };

  // Removal under seeded HashUtils works.
  i := 0;
  while (i < 100) {
    seededA := CM.remove(seededA, seedA, i);
    i += 1;
  };
  assert CM.size(seededA) == 100;
  assert CM.get(seededA, seedA, 0) == null;
  assert CM.get(seededA, seedA, 100) == ?1000;

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // Synthetic colliding hash — exercise the #collision bucket path end-to-end.
  // All keys hash to the same value; ChampMap must still satisfy get/put/
  // remove correctness via the equality fallback.
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let allCollide : CM.HashUtils<Nat> = (
    func(_k : Nat) : Nat32 = 42,
    func(a : Nat, b : Nat) : Bool = a == b,
  );

  var coll = CM.empty<Nat, Text>();
  // Push past ARRAY_MAX (16) to force promotion; everything will land in one
  // collision bucket because all keys share hash 42.
  i := 0;
  while (i < 50) {
    coll := CM.put(coll, allCollide, i, Nat.toText(i));
    i += 1;
  };
  assert CM.size(coll) == 50;
  i := 0;
  while (i < 50) {
    assert CM.get(coll, allCollide, i) == ?Nat.toText(i);
    i += 1;
  };
  // Replacement inside collision bucket
  coll := CM.put(coll, allCollide, 7, "seven");
  assert CM.get(coll, allCollide, 7) == ?"seven";
  assert CM.size(coll) == 50;
  // Removal inside collision bucket
  coll := CM.remove(coll, allCollide, 25);
  assert CM.size(coll) == 49;
  assert CM.get(coll, allCollide, 25) == null;
  assert CM.get(coll, allCollide, 24) == ?"24";
  assert CM.get(coll, allCollide, 26) == ?"26";

  // Iterating a fully-collided map returns every entry exactly once.
  var seenCount = 0;
  for ((_, _) in CM.entries(coll)) { seenCount += 1 };
  assert seenCount == 49;

  // Collapse: removing entries back down to 1 must keep the survivor reachable.
  i := 0;
  while (i < 50) {
    if (i != 7) coll := CM.remove(coll, allCollide, i);
    i += 1;
  };
  assert CM.size(coll) == 1;
  assert CM.get(coll, allCollide, 7) == ?"seven";

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // mergeEntries short-circuit — two distinct keys that collide must promote
  // straight to a #collision (no chain of empty 1-child branches). We can't
  // observe the trie shape directly, but we can observe the consequence:
  // building a small two-key collision pair should be cheap and validate()
  // should accept the result.
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  var pair = CM.empty<Nat, Nat>();
  pair := CM.put(pair, allCollide, 1, 100);
  pair := CM.put(pair, allCollide, 2, 200);
  // Force promotion past ARRAY_MAX with one extra non-colliding-equal entry
  // that still hashes to 42 (everything does under allCollide).
  i := 3;
  while (i < 20) {
    pair := CM.put(pair, allCollide, i, i * 100);
    i += 1;
  };
  assert CM.size(pair) == 19;
  switch (CM.validate<Nat, Nat>(pair, allCollide)) {
    case (#ok) {};
    case (#err msg) { Runtime.trap("validate rejected legitimate collision map: " # msg) };
  };

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // validate() — well-formed maps must pass.
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  switch (CM.validate<Nat, Text>(CM.empty(), nhash)) {
    case (#ok) {};
    case (#err msg) { Runtime.trap("validate rejected #empty: " # msg) };
  };

  let small = CM.fromIter<Nat, Text>([(1, "a"), (2, "b"), (3, "c")].vals(), nhash);
  switch (CM.validate<Nat, Text>(small, nhash)) {
    case (#ok) {};
    case (#err msg) { Runtime.trap("validate rejected small arrayMap: " # msg) };
  };

  // Larger trie map
  var big = CM.empty<Nat, Nat>();
  i := 0;
  while (i < 5_000) {
    big := CM.put(big, nhash, i, i);
    i += 1;
  };
  switch (CM.validate<Nat, Nat>(big, nhash)) {
    case (#ok) {};
    case (#err msg) { Runtime.trap("validate rejected legitimate trie of 5000: " # msg) };
  };

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // validate() — malformed maps must be rejected (these simulate values an
  // attacker could submit via candid against a method that accepts Map<K,V>).
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  // Empty arrayMap (should be #empty instead)
  let badEmptyArray : CM.Map<Nat, Text> = #arrayMap([var]);
  switch (CM.validate<Nat, Text>(badEmptyArray, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted empty arrayMap") };
  };

  // arrayMap above ARRAY_MAX (17 entries — promoteToTrie should have fired)
  let oversized = [var
    (0, "0"), (1, "1"), (2, "2"), (3, "3"), (4, "4"), (5, "5"),
    (6, "6"), (7, "7"), (8, "8"), (9, "9"), (10, "10"), (11, "11"),
    (12, "12"), (13, "13"), (14, "14"), (15, "15"), (16, "16"),
  ];
  let badOversized : CM.Map<Nat, Text> = #arrayMap(oversized);
  switch (CM.validate<Nat, Text>(badOversized, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted arrayMap with 17 entries") };
  };

  // arrayMap with duplicate keys
  let dup = [var (1, "a"), (2, "b"), (1, "c")];
  let badDup : CM.Map<Nat, Text> = #arrayMap(dup);
  switch (CM.validate<Nat, Text>(badDup, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted arrayMap with duplicate keys") };
  };

  // collision node with only one entry (must collapse to inline in a real map)
  let badCollSingle : CM.Map<Nat, Text> = #trie(#collision(7, [var (1, "a")]));
  switch (CM.validate<Nat, Text>(badCollSingle, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted single-entry collision bucket") };
  };

  // collision node with duplicate keys
  let badCollDup : CM.Map<Nat, Text> = #trie(#collision(7, [var (1, "a"), (1, "b")]));
  switch (CM.validate<Nat, Text>(badCollDup, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted collision bucket with duplicate keys") };
  };

  // branch with datamap/nodemap overlap
  let badOverlap : CM.Map<Nat, Text> = #trie(#branch(0x1, 0x1, [var (0, 1, "a")], [var #branch(0, 0, [var], [var])]));
  switch (CM.validate<Nat, Text>(badOverlap, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted branch with overlapping datamap/nodemap") };
  };

  // branch with size mismatch (datamap says 2 entries, data has 1)
  let badSizeMismatch : CM.Map<Nat, Text> = #trie(#branch(0x3, 0, [var (0, 1, "a")], [var]));
  switch (CM.validate<Nat, Text>(badSizeMismatch, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted branch with data size != popcount(datamap)") };
  };

  // branch with inline entry whose hash does not route to its slot
  // datamap=0x2 means slot 1; entry hash 0 routes to slot 0
  let badRoute : CM.Map<Nat, Text> = #trie(#branch(0x2, 0, [var (0, 1, "a")], [var]));
  switch (CM.validate<Nat, Text>(badRoute, nhash)) {
    case (#err _) {};
    case (#ok) { Runtime.trap("validate accepted branch with mis-routed inline entry") };
  };

  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
  // A round-tripped map (the recommended trust-boundary pattern) must always
  // validate.
  ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

  let roundTripped = CM.map<Nat, Nat, Text>(big, func(_k : Nat, v : Nat) : Text { Nat.toText(v) });
  switch (CM.validate<Nat, Text>(roundTripped, nhash)) {
    case (#ok) {};
    case (#err msg) { Runtime.trap("validate rejected round-tripped map: " # msg) };
  };
  assert CM.size(roundTripped) == 5_000;

  Debug.print("All Security tests passed");
};
