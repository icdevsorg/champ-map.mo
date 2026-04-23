import Bench "mo:bench";
import CM "../src/lib";
import CorePMap "mo:core/pure/Map";
import Nat "mo:core/Nat";
import Text "mo:core/Text";
import Array "mo:core/Array";

module {
  public func init() : Bench.Bench {
    let bench = Bench.Bench();

    bench.name("ChampMap vs core/pure/Map – pure operation cost, Nat keys");
    bench.description("Maps pre-built outside runner. Each cell measures ONLY the operation (except build).");

    bench.rows([
      "build",
      "get",
      "replace",
      "delete",
      "clone",
      "iterate",
    ]);

    bench.cols([
      "CM 10",
      "CM 100",
      "CM 1_000",
      "CM 10_000",
      "CM 100_000",
      "Core 10",
      "Core 100",
      "Core 1_000",
      "Core 10_000",
      "Core 100_000",
    ]);

    // ── Pre-generate keys ──────────────────────────────────────

    let N = 100_000;
    let natKeys = Array.tabulate<Nat>(N, func(i) { i });

    let { nhash } = CM;
    let natCompare = Nat.compare;
    let sizes = [10, 100, 1_000, 10_000, 100_000];

    // ── Pre-build all maps (NOT measured) ──────────────────────

    // ChampMap – persistent/immutable, safe to share across all ops
    let cmaps = Array.tabulate<CM.Map<Nat, Nat>>(5, func(si) {
      var m = CM.empty<Nat, Nat>();
      var j = 0;
      while (j < sizes[si]) { m := CM.put(m, nhash, natKeys[j], j); j += 1 };
      m;
    });

    // Core pure/Map – persistent/immutable, safe to share
    let coremaps = Array.tabulate<CorePMap.Map<Nat, Nat>>(5, func(si) {
      var m = CorePMap.empty<Nat, Nat>();
      var j = 0;
      while (j < sizes[si]) { m := CorePMap.add(m, natCompare, natKeys[j], j); j += 1 };
      m;
    });

    // ── Runner (ONLY the operation is measured) ────────────────

    bench.runner(func(row : Text, col : Text) {

      let isCM = Text.startsWith(col, #text("CM"));
      let si : Nat = if (Text.endsWith(col, #text("100_000"))) 4
        else if (Text.endsWith(col, #text("10_000"))) 3
        else if (Text.endsWith(col, #text("1_000"))) 2
        else if (Text.endsWith(col, #text("100"))) 1
        else 0;
      let size = sizes[si];

      // ── ChampMap (CHAMP) ─────────────────────────────────────
      if (isCM) {
        if (row == "build") {
          var m = CM.empty<Nat, Nat>();
          var i = 0;
          while (i < size) { m := CM.put(m, nhash, natKeys[i], i); i += 1 };
        } else if (row == "get") {
          var i = 0;
          while (i < size) { ignore CM.get(cmaps[si], nhash, natKeys[i]); i += 1 };
        } else if (row == "replace") {
          var m = cmaps[si];
          var i = 0;
          while (i < size) { m := CM.put(m, nhash, natKeys[i], i + 1); i += 1 };
        } else if (row == "delete") {
          var m = cmaps[si];
          var i = 0;
          while (i < size) { m := CM.remove(m, nhash, natKeys[i]); i += 1 };
        } else if (row == "clone") {
          ignore CM.clone(cmaps[si]);
        } else if (row == "iterate") {
          for ((_k, _v) in CM.entries(cmaps[si])) {};
        };

      // ── core/pure/Map (RBTree) ──────────────────────────────
      } else {
        if (row == "build") {
          var m = CorePMap.empty<Nat, Nat>();
          var i = 0;
          while (i < size) { m := CorePMap.add(m, natCompare, natKeys[i], i); i += 1 };
        } else if (row == "get") {
          var i = 0;
          while (i < size) { ignore CorePMap.get(coremaps[si], natCompare, natKeys[i]); i += 1 };
        } else if (row == "replace") {
          var m = coremaps[si];
          var i = 0;
          while (i < size) { m := CorePMap.add(m, natCompare, natKeys[i], i + 1); i += 1 };
        } else if (row == "delete") {
          var m = coremaps[si];
          var i = 0;
          while (i < size) { m := CorePMap.remove(m, natCompare, natKeys[i]); i += 1 };
        } else if (row == "clone") {
          let _copy = coremaps[si]; // O(1) – persistent identity
        } else if (row == "iterate") {
          for ((_k, _v) in CorePMap.entries(coremaps[si])) {};
        };
      };
    });

    bench;
  };
};
