import Bench "mo:bench";
import Nat "mo:core/Nat";
import Array "mo:core/Array";
import Text "mo:core/Text";
import VarArray "mo:core/VarArray";
import CorePMap "mo:core/pure/Map";
import Order "mo:core/Order";

module {

  // ------------------------------------------------------------------
  // Collision-bucket strategy micro-benchmark
  //
  // Compares three approaches for what happens INSIDE a collision 
  // bucket (all entries share the same 32-bit hash):
  //
  //   flat_copy  — current champ_map: grow-by-1 array copy on each
  //                insert, linear scan on lookup.  O(n²) build, O(n) get.
  //
  //   flat_vec   — vector-style doubling growth, linear scan on lookup.
  //                O(n) amortized build, O(n) get.
  //
  //   rbtree     — red-black tree (mo:core/pure/Map) with compare.
  //                O(n log n) build, O(log n) get.
  //
  // Sizes: 10, 50, 100, 500
  // ------------------------------------------------------------------

  public func init() : Bench.Bench {
    let bench = Bench.Bench();

    bench.name("Collision bucket strategy: flat-copy vs flat-vec vs rbtree");
    bench.description("Raw cost of insert-all / lookup-all / remove-all inside a collision bucket of N entries.");

    bench.rows([
      "insert_all",
      "lookup_all",
      "remove_all",
    ]);

    let sizes = [10, 50, 100, 500];
    let sizeLabels = ["10", "50", "100", "500"];
    let prefixes = ["flat_copy", "flat_vec", "rbtree"];

    let cols = Array.tabulate<Text>(prefixes.size() * sizes.size(), func(i) {
      let pi = i / sizes.size();
      let si = i % sizes.size();
      prefixes[pi] # "_" # sizeLabels[si];
    });
    bench.cols(cols);

    let maxN = 500;
    let keys = Array.tabulate<Nat>(maxN, func(i) { i });

    // ------- Pre-build structures for lookup/remove benchmarks -------

    // flat_copy: [var (Nat, Nat)] built by grow-by-1
    let flatCopyBuilt = Array.tabulate<[var (Nat, Nat)]>(sizes.size(), func(si) {
      let n = sizes[si];
      var arr : [var (Nat, Nat)] = [var];
      var j = 0;
      while (j < n) {
        let old = arr;
        let newArr = VarArray.repeat<(Nat, Nat)>((keys[j], j), old.size() + 1);
        var k = 0;
        while (k < old.size()) { newArr[k] := old[k]; k += 1 };
        newArr[old.size()] := (keys[j], j);
        arr := newArr;
        j += 1;
      };
      arr;
    });

    // flat_vec: same content, built as a single tabulate (represents pre-built vector)
    let flatVecBuilt = Array.tabulate<[var (Nat, Nat)]>(sizes.size(), func(si) {
      let n = sizes[si];
      VarArray.repeat<(Nat, Nat)>((0, 0), n);
    });
    // fill
    for (si in flatVecBuilt.keys()) {
      let n = sizes[si];
      let arr = flatVecBuilt[si];
      var j = 0;
      while (j < n) { arr[j] := (keys[j], j); j += 1 };
    };

    // rbtree: pre-built
    let natCompare = Nat.compare;
    let treeBuilt = Array.tabulate<CorePMap.Map<Nat, Nat>>(sizes.size(), func(si) {
      let n = sizes[si];
      var m = CorePMap.empty<Nat, Nat>();
      var j = 0;
      while (j < n) { m := CorePMap.add(m, natCompare, keys[j], j); j += 1 };
      m;
    });

    // ------- Runner -------

    bench.runner(func(row : Text, col : Text) {

      let isFlat = Text.startsWith(col, #text("flat_copy"));
      let isVec = Text.startsWith(col, #text("flat_vec"));

      let si : Nat = if (Text.endsWith(col, #text("_500"))) 3
        else if (Text.endsWith(col, #text("_100"))) 2
        else if (Text.endsWith(col, #text("_50"))) 1
        else 0;
      let size = sizes[si];

      // ── flat_copy (current champ_map behavior) ───────────────
      if (isFlat) {
        if (row == "insert_all") {
          // Grow-by-1 array copy each insert
          var arr : [var (Nat, Nat)] = [var];
          var j = 0;
          while (j < size) {
            let old = arr;
            let s = old.size();
            let newArr = VarArray.repeat<(Nat, Nat)>((keys[j], j), s + 1);
            var k = 0;
            while (k < s) { newArr[k] := old[k]; k += 1 };
            newArr[s] := (keys[j], j);
            arr := newArr;
            j += 1;
          };
        } else if (row == "lookup_all") {
          let arr = flatCopyBuilt[si];
          let s = arr.size();
          var j = 0;
          while (j < size) {
            let target = keys[j];
            var k = 0;
            label scan while (k < s) {
              if (arr[k].0 == target) break scan;
              k += 1;
            };
            j += 1;
          };
        } else if (row == "remove_all") {
          var arr = flatCopyBuilt[si];
          var j = 0;
          while (j < size) {
            let target = keys[j];
            let s = arr.size();
            var found : Nat = s; // sentinel
            var k = 0;
            label scan while (k < s) {
              if (arr[k].0 == target) { found := k; break scan };
              k += 1;
            };
            if (found < s) {
              let newArr = VarArray.repeat<(Nat, Nat)>((0, 0), s - 1 : Nat);
              var d = 0;
              k := 0;
              while (k < s) {
                if (k != found) { newArr[d] := arr[k]; d += 1 };
                k += 1;
              };
              arr := newArr;
            };
            j += 1;
          };
        };

      // ── flat_vec (vector-style doubling) ─────────────────────
      } else if (isVec) {
        if (row == "insert_all") {
          // Vector-style: double capacity when full
          var arr = VarArray.repeat<(Nat, Nat)>((0, 0), 4);
          var len = 0;
          var j = 0;
          while (j < size) {
            if (len == arr.size()) {
              // double
              let newArr = VarArray.repeat<(Nat, Nat)>((0, 0), arr.size() * 2);
              var k = 0;
              while (k < len) { newArr[k] := arr[k]; k += 1 };
              arr := newArr;
            };
            arr[len] := (keys[j], j);
            len += 1;
            j += 1;
          };
        } else if (row == "lookup_all") {
          let arr = flatVecBuilt[si];
          let s = arr.size();
          var j = 0;
          while (j < size) {
            let target = keys[j];
            var k = 0;
            label scan while (k < s) {
              if (arr[k].0 == target) break scan;
              k += 1;
            };
            j += 1;
          };
        } else if (row == "remove_all") {
          // For vector remove: swap-remove (O(1) per remove, no order preservation needed in bucket)
          let arr = VarArray.repeat<(Nat, Nat)>((0, 0), size);
          var len = size;
          var k = 0;
          while (k < size) { arr[k] := flatVecBuilt[si][k]; k += 1 };

          var j = 0;
          while (j < size) {
            let target = keys[j];
            var found : Nat = len; // sentinel
            k := 0;
            label scan while (k < len) {
              if (arr[k].0 == target) { found := k; break scan };
              k += 1;
            };
            if (found < len) {
              len -= 1;
              if (found < len) {
                arr[found] := arr[len]; // swap-remove
              };
            };
            j += 1;
          };
        };

      // ── rbtree (mo:core/pure/Map) ───────────────────────────
      } else {
        if (row == "insert_all") {
          var m = CorePMap.empty<Nat, Nat>();
          var j = 0;
          while (j < size) { m := CorePMap.add(m, natCompare, keys[j], j); j += 1 };
        } else if (row == "lookup_all") {
          let m = treeBuilt[si];
          var j = 0;
          while (j < size) { ignore CorePMap.get(m, natCompare, keys[j]); j += 1 };
        } else if (row == "remove_all") {
          var m = treeBuilt[si];
          var j = 0;
          while (j < size) { m := CorePMap.remove(m, natCompare, keys[j]); j += 1 };
        };
      };
    });

    bench;
  };
};
