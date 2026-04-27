# ChampMap Skill Tests

Maintainer-only file. Use this to check whether the skill triggers in the right situations and produces the right kind of answer. This is not runtime guidance for a consuming agent.

## Obvious triggers (MUST fire)

1. **"Create a simple key-value store canister using champ-map"**
   Expected: Generates a canister actor with CM import, stable var, put/get/size methods using correct HashUtils.
   Result: Not run yet.

2. **"I need to store Principal -> Nat mappings in my canister. How do I use ChampMap?"**
   Expected: Uses `CM.phash`, shows put/get pattern, mentions `withSeed` since Principal keys likely come from callers.
   Result: Not run yet.

3. **"My mo:map canister is trapping at 5 million entries. How do I migrate to ChampMap?"**
   Expected: Explains the 4M wall, shows migration pattern, notes loss of insertion order, provides code to convert.
   Result: Not run yet.

4. **"How do I safely accept a batch of entries from a public method using ChampMap?"**
   Expected: Shows trust boundary pattern — accept `[(K, V)]`, use `withSeed`, `fromIter`. References security considerations.
   Result: Not run yet.

## Adjacent cases (decide case-by-case)

5. **"What's the most efficient map for Motoko?"**
   Expected: May or may not trigger. If it does, should compare ChampMap vs mo:core/pure/Map vs mo:map with trade-offs, not just shill ChampMap.
   Result: Not run yet.

6. **"How do I iterate over a large map in a canister without running out of cycles?"**
   Expected: Should trigger if ChampMap is in context. Shows `collectBatch` pattern with bounded chunks.
   Result: Not run yet.

## Clear non-triggers (MUST NOT fire)

7. **"How do I create a HashMap in Python?"**
   Expected: Does NOT trigger. This is a different language entirely.
   Result: Not run yet.

8. **"Explain how red-black trees work"**
   Expected: Does NOT trigger. This is about a different data structure, not ChampMap.
   Result: Not run yet.
