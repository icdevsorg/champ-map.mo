import Bench "mo:bench";
import Nat32 "mo:core/Nat32";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Blob "mo:core/Blob";
import CM "../src/lib";

module {

  // ------------------------------------------------------------------
  // Collision micro-benchmark
  //
  // We compare three scenarios:
  //   A) "same_hash" – ALL keys hash to the same value (worst case).
  //      This forces everything into #collision buckets in the current
  //      implementation.  Measures O(n²) growth.
  //   B) "rehash_sim" – Simulates a secondary-hash fix by using a
  //      two-round hash that scrambles differently.  Even though all
  //      primary hashes collide, the secondary hash spreads them back
  //      into normal trie branches.
  //   C) "normal" – Normal (non-colliding) keys as a baseline.
  //
  // Operations measured: build, get-all, remove-all.
  // Sizes: 10, 50, 100, 200 (200 is near the Nat8 trap limit of 255).
  // ------------------------------------------------------------------

  // A constant-hash function – forces all keys into one collision bucket
  func constHash(_k : Nat) : Nat32 { 42 };
  let constEq = func(a : Nat, b : Nat) : Bool { a == b };
  let constHashUtils : CM.HashUtils<Nat> = (constHash, constEq);

  // A "secondary hash" simulation: primary hash collides, but we
  // rehash through a different scramble.  In practice, a real fix would
  // detect shift>=32 and switch to hash2.  Here we just provide a
  // completely independent hash to show the trie stays balanced.
  func rehash(k : Nat) : Nat32 {
    // splitmix-style but with different constants than the built-in nhash
    var h : Nat32 = Nat32.fromIntWrap(k) +% 0x9e3779b9;
    h := (h ^ (h >> 16)) *% 0x85ebca6b;
    h := (h ^ (h >> 13)) *% 0xc2b2ae35;
    (h ^ (h >> 16)) & 0x3fffffff;
  };
  let rehashUtils : CM.HashUtils<Nat> = (rehash, constEq);

  public func init() : Bench.Bench {
    let bench = Bench.Bench();

    bench.name("Collision handling: baseline vs secondary-hash vs normal");
    bench.description("Measures build / get / remove under forced hash collisions (same_hash), " #
      "secondary-hash re-spread (rehash_sim), and normal hashing.");

    bench.rows([
      "build",
      "get_all",
      "remove_all",
    ]);

    let sizes = [10, 50, 100, 200];
    let sizeLabels = ["10", "50", "100", "200"];
    let prefixes = ["same_hash", "rehash_sim", "normal"];

    // Build column labels: same_hash_10, same_hash_50, …, normal_200
    let cols = Array.tabulate<Text>(prefixes.size() * sizes.size(), func(i) {
      let pi = i / sizes.size();
      let si = i % sizes.size();
      prefixes[pi] # "_" # sizeLabels[si];
    });
    bench.cols(cols);

    // Pre-generate keys
    let maxN = 200;
    let keys = Array.tabulate<Nat>(maxN, func(i) { i });

    // Pre-build maps for get/remove (not timed)
    let { nhash } = CM;

    let sameMaps = Array.tabulate<CM.Map<Nat, Nat>>(sizes.size(), func(si) {
      var m = CM.empty<Nat, Nat>();
      var j = 0;
      while (j < sizes[si]) { m := CM.put(m, constHashUtils, keys[j], j); j += 1 };
      m;
    });

    let rehashMaps = Array.tabulate<CM.Map<Nat, Nat>>(sizes.size(), func(si) {
      var m = CM.empty<Nat, Nat>();
      var j = 0;
      while (j < sizes[si]) { m := CM.put(m, rehashUtils, keys[j], j); j += 1 };
      m;
    });

    let normalMaps = Array.tabulate<CM.Map<Nat, Nat>>(sizes.size(), func(si) {
      var m = CM.empty<Nat, Nat>();
      var j = 0;
      while (j < sizes[si]) { m := CM.put(m, nhash, keys[j], j); j += 1 };
      m;
    });

    bench.runner(func(row : Text, col : Text) {

      // Parse column
      let isSame = Text.startsWith(col, #text("same_hash"));
      let isRehash = Text.startsWith(col, #text("rehash_sim"));

      let si : Nat = if (Text.endsWith(col, #text("_200"))) 3
        else if (Text.endsWith(col, #text("_100"))) 2
        else if (Text.endsWith(col, #text("_50"))) 1
        else 0;
      let size = sizes[si];

      let hu : CM.HashUtils<Nat> = if (isSame) constHashUtils
        else if (isRehash) rehashUtils
        else nhash;

      let prebuilt = if (isSame) sameMaps[si]
        else if (isRehash) rehashMaps[si]
        else normalMaps[si];

      if (row == "build") {
        var m = CM.empty<Nat, Nat>();
        var i = 0;
        while (i < size) { m := CM.put(m, hu, keys[i], i); i += 1 };
      } else if (row == "get_all") {
        var i = 0;
        while (i < size) { ignore CM.get(prebuilt, hu, keys[i]); i += 1 };
      } else if (row == "remove_all") {
        var m = prebuilt;
        var i = 0;
        while (i < size) { m := CM.remove(m, hu, keys[i]); i += 1 };
      };
    });

    bench;
  };
};
