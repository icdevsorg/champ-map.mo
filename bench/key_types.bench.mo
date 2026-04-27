import Bench "mo:bench";
import Blob "mo:core/Blob";
import Array "mo:core/Array";
import Text "mo:core/Text";
import Nat "mo:core/Nat";
import Nat64 "mo:core/Nat64";
import CM "../src/lib";
import HamtPMap "mo:hamt/pure/HashMap";
import HamtTypes "mo:hamt/Types";

module {
  public func init() : Bench.Bench {
    let bench = Bench.Bench();

    bench.name("ChampMap vs hamt/pure/HashMap – Text and Blob keys");
    bench.description("Hash-map-only comparison across key types. Maps are pre-built outside runner. Each cell measures ONLY the operation (except build).");

    bench.rows([
      "build",
      "get",
      "replace",
      "delete",
      "clone",
      "iterate",
    ]);

    bench.cols([
      "CM/Text 10",
      "CM/Text 16",
      "CM/Text 100",
      "CM/Text 1_000",
      "CM/Text 10_000",
      "CM/Text 100_000",
      "HAMT/Text 10",
      "HAMT/Text 16",
      "HAMT/Text 100",
      "HAMT/Text 1_000",
      "HAMT/Text 10_000",
      "HAMT/Text 100_000",
      "CM/Blob 10",
      "CM/Blob 16",
      "CM/Blob 100",
      "CM/Blob 1_000",
      "CM/Blob 10_000",
      "CM/Blob 100_000",
      "HAMT/Blob 10",
      "HAMT/Blob 16",
      "HAMT/Blob 100",
      "HAMT/Blob 1_000",
      "HAMT/Blob 10_000",
      "HAMT/Blob 100_000",
    ]);

    let N = 100_000;
    let sizes = [10, 16, 100, 1_000, 10_000, 100_000];

    let textKeys = Array.tabulate<Text>(N, func(i) { "key-" # Nat.toText(i) });
    let blobKeys = Array.tabulate<Blob>(N, func(i) { Text.encodeUtf8(textKeys[i]) });

    let { thash; bhash } = CM;
    let hamtSeed : HamtTypes.Seed = (0 : Nat64, 0 : Nat64);
    let hamtTextHash = HamtTypes.Text.hash;
    let hamtBlobHash = HamtTypes.Blob.hash;

    let cmTextMaps = Array.tabulate<CM.Map<Text, Nat>>(sizes.size(), func(si) {
      var m = CM.empty<Text, Nat>();
      var j = 0;
      while (j < sizes[si]) {
        m := CM.put(m, thash, textKeys[j], j);
        j += 1;
      };
      m;
    });

    let hamtTextMaps = Array.tabulate<HamtPMap.HashMap<Text, Nat>>(sizes.size(), func(si) {
      let hash = hamtTextHash;
      let equal = Text.equal;
      var m = HamtPMap.empty<Text, Nat>(hamtSeed);
      var j = 0;
      while (j < sizes[si]) {
        m := HamtPMap.add(m, textKeys[j], j);
        j += 1;
      };
      m;
    });

    let cmBlobMaps = Array.tabulate<CM.Map<Blob, Nat>>(sizes.size(), func(si) {
      var m = CM.empty<Blob, Nat>();
      var j = 0;
      while (j < sizes[si]) {
        m := CM.put(m, bhash, blobKeys[j], j);
        j += 1;
      };
      m;
    });

    let hamtBlobMaps = Array.tabulate<HamtPMap.HashMap<Blob, Nat>>(sizes.size(), func(si) {
      let hash = hamtBlobHash;
      let equal = Blob.equal;
      var m = HamtPMap.empty<Blob, Nat>(hamtSeed);
      var j = 0;
      while (j < sizes[si]) {
        m := HamtPMap.add(m, blobKeys[j], j);
        j += 1;
      };
      m;
    });

    bench.runner(func(row : Text, col : Text) {
      let isText = Text.contains(col, #text("Text"));
      let isBlob = Text.contains(col, #text("Blob"));
      let isCM = Text.startsWith(col, #text("CM/"));
      let isHAMT = Text.startsWith(col, #text("HAMT/"));
      let si : Nat = if (Text.endsWith(col, #text("100_000"))) 5
        else if (Text.endsWith(col, #text("10_000"))) 4
        else if (Text.endsWith(col, #text("1_000"))) 3
        else if (Text.endsWith(col, #text("100"))) 2
        else if (Text.endsWith(col, #text("16"))) 1
        else 0;
      let size = sizes[si];

      if (isText and isCM) {
        if (row == "build") {
          var m = CM.empty<Text, Nat>();
          var i = 0;
          while (i < size) { m := CM.put(m, thash, textKeys[i], i); i += 1 };
        } else if (row == "get") {
          var i = 0;
          while (i < size) { ignore CM.get(cmTextMaps[si], thash, textKeys[i]); i += 1 };
        } else if (row == "replace") {
          var m = cmTextMaps[si];
          var i = 0;
          while (i < size) { m := CM.put(m, thash, textKeys[i], i + 1); i += 1 };
        } else if (row == "delete") {
          var m = cmTextMaps[si];
          var i = 0;
          while (i < size) { m := CM.remove(m, thash, textKeys[i]); i += 1 };
        } else if (row == "clone") {
          ignore CM.clone(cmTextMaps[si]);
        } else if (row == "iterate") {
          for ((_k, _v) in CM.entries(cmTextMaps[si])) {};
        };
      } else if (isText and isHAMT) {
        let hash = hamtTextHash;
        let equal = Text.equal;
        if (row == "build") {
          var m = HamtPMap.empty<Text, Nat>(hamtSeed);
          var i = 0;
          while (i < size) { m := HamtPMap.add(m, textKeys[i], i); i += 1 };
        } else if (row == "get") {
          var i = 0;
          while (i < size) { ignore HamtPMap.get(hamtTextMaps[si], textKeys[i]); i += 1 };
        } else if (row == "replace") {
          var m = hamtTextMaps[si];
          var i = 0;
          while (i < size) { m := HamtPMap.add(m, textKeys[i], i + 1); i += 1 };
        } else if (row == "delete") {
          var m = hamtTextMaps[si];
          var i = 0;
          while (i < size) { m := HamtPMap.delete(m, textKeys[i]); i += 1 };
        } else if (row == "clone") {
          let _copy = hamtTextMaps[si];
        } else if (row == "iterate") {
          for ((_k, _v) in HamtPMap.entries(hamtTextMaps[si])) {};
        };
      } else if (isBlob and isCM) {
        if (row == "build") {
          var m = CM.empty<Blob, Nat>();
          var i = 0;
          while (i < size) { m := CM.put(m, bhash, blobKeys[i], i); i += 1 };
        } else if (row == "get") {
          var i = 0;
          while (i < size) { ignore CM.get(cmBlobMaps[si], bhash, blobKeys[i]); i += 1 };
        } else if (row == "replace") {
          var m = cmBlobMaps[si];
          var i = 0;
          while (i < size) { m := CM.put(m, bhash, blobKeys[i], i + 1); i += 1 };
        } else if (row == "delete") {
          var m = cmBlobMaps[si];
          var i = 0;
          while (i < size) { m := CM.remove(m, bhash, blobKeys[i]); i += 1 };
        } else if (row == "clone") {
          ignore CM.clone(cmBlobMaps[si]);
        } else if (row == "iterate") {
          for ((_k, _v) in CM.entries(cmBlobMaps[si])) {};
        };
      } else {
        let hash = hamtBlobHash;
        let equal = Blob.equal;
        if (row == "build") {
          var m = HamtPMap.empty<Blob, Nat>(hamtSeed);
          var i = 0;
          while (i < size) { m := HamtPMap.add(m, blobKeys[i], i); i += 1 };
        } else if (row == "get") {
          var i = 0;
          while (i < size) { ignore HamtPMap.get(hamtBlobMaps[si], blobKeys[i]); i += 1 };
        } else if (row == "replace") {
          var m = hamtBlobMaps[si];
          var i = 0;
          while (i < size) { m := HamtPMap.add(m, blobKeys[i], i + 1); i += 1 };
        } else if (row == "delete") {
          var m = hamtBlobMaps[si];
          var i = 0;
          while (i < size) { m := HamtPMap.delete(m, blobKeys[i]); i += 1 };
        } else if (row == "clone") {
          let _copy = hamtBlobMaps[si];
        } else if (row == "iterate") {
          for ((_k, _v) in HamtPMap.entries(hamtBlobMaps[si])) {};
        };
      };
    });

    bench;
  };
};