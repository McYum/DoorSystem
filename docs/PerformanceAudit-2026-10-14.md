# Dummy-kill performance investigation, 2026-10-14

Repository: McYum/DoorSystem (https://github.com/McYum/DoorSystem)
Local directory: `D:\RevoltAssets\Codebase\Doors\System\DoorSystem`
Branch: `perf/door-requirement-scan`

## Verified fix: reduce repeated key-check work

Files: `ReplicatedStorage/DoorSystemShared/DoorAccess.luau`,
`tests/DoorRequirementLookup.luau`, and this audit.

While profiling lethal dummy hits, DoorClient repeatedly occupied 8–14 ms of
the main thread. Nearby locked doors checked every descendant in Inventory,
Backpack and Character; each irrelevant geometry node read category, two key
attributes and display name before being rejected for the wrong category.

The five-line fix rejects wrong-category non-DoorKey candidates immediately.
DoorKey candidates still reach the original master/wildcard bypass, and all
other matching rules remain unchanged. No cache, permission rule, interaction,
door motion, or visual behavior is changed.

Verification:

- Native regression test failed on the original helpers: four attribute reads
  for an unrelated geometry node. Patched helpers use one read.
- Studio Edit and Play Client tests pass: exact/display names, name-only and
  key-only matches, wrong keys/categories, linked ObjectValues, DoorKeyId
  precedence, master/wildcard bypass, other categories, empty criteria.
- Paired client benchmark, ten alternating passes over the same five nearby
  doors: original 8.424 ms/pass, patched 4.482 ms/pass; identical allow/deny
  decisions and reasons. Repeat: 6.451 vs 3.202 ms/pass.
- With the production patch installed in Play, the sampled DoorClient refresh
  during a lethal Knife sequence measured 4.191 ms versus the earlier 7.909 ms
  refresh. These are separate runs, not a whole-frame controlled A/B.
- Independent review approved the change; its minor name-only/key-only coverage
  suggestion was added and passed. `git diff --check` passed.

Runtime regression status: verified for these cases. The preexisting thirteen-line
DoorClient decal-visibility edit is preserved, unstaged and excluded from this fix.
Studio's shared DoorAccess source was updated; no game publication or main merge.

## Kill-specific investigation and limits

The user subsequently clarified that G19 body-shot and headshot kills both hitch.
Real projectile simulation, server damage and natural death were exercised for
both types, with particles enabled and no IrisPerf disable flags set.

- Body-shot window: maximum 24.739 ms CPU frame (frame 60690, absolute 1069141),
  death marker frame 60697 / absolute 1069148 measured 23.997 ms.
- Headshot window: maximum 22.161 ms CPU frame (71049 / absolute 1079500).
  The target had `DeathHeadshot = true` after the shot.
- Headshot capture's GPU Scene maximum was 7.719 ms across its full history;
  the sampled run does not show a matching large GPU stall.
- Death windows contain geometry regeneration and replication work. Engine
  timer names do not identify the exact source responsible for the remaining cost.

The door fix reduces a demonstrated overlapping main-thread cost. It is not a
claim that G19 kills are now lag-free, nor does it isolate every reported giant
stall. Avoid assigning tool-execution pauses to gameplay: an initial direct-tool
kill capture contained a 744 ms frame that was not reproduced when scheduling
the kill after the tool returned. Custom profiler timer names have a `::` prefix;
the final death-window analyzer matches `*DeathPerfMarker*` explicitly.

## Cumulative checklist

- [x] WeaponSystem: expired surface listeners, screen splatters, laser-ignore
  entries and repeated missing display-asset scans; see that repository's audit.
- [x] TacticalNotificationSystem: accumulating Kick renderers and repeated scaling;
  see its `perf/first-person-kick-lifecycle` branch and audit.
- [x] DoorSystem: reduce verified repeated requirement-check work (this fix).
- [ ] Complete G19 death-specific fixes and repeat natural body/head kills.
- [ ] Attribute remaining geometry/replication costs and prolonged-session stalls.

## Follow-up: native key candidate selection, 2026-10-15

The remaining traversal still sent every inventory/character descendant through
Lua for category-based checks. Use the native `QueryDescendants` selector
`[$Category], ObjectValue` in those two loops. A direct matching item must have a
Category attribute; all ObjectValues remain candidates because their linked item
can be outside the inventory and their own Category can differ. The original
matching functions, root handling, and category-nil GetDescendants fallback stay
unchanged. No cache, listener, inventory mutation, or gameplay rule was added.

This API requires serial execution (QueryDescendants is not parallel-safe).
Current DoorClient/DoorService callers are serial; repository searches found no
ConnectParallel/desynchronize caller. No synchronization wrapper was introduced.
API reference: https://create.roblox.com/docs/reference/engine/classes/Instance#QueryDescendants

Native verification in Inventory_Dev:

- `tests/DoorCandidateQuery.luau`: before failed its performance assertion with
  1,503 Lua candidate visits; after passes 27 assertions with 2 visits. Passed in
  Edit, Play Client, and Play Server. Covers roots, nesting, links, late metadata,
  reparent/removal, exact/display names, category-nil fallback, master/wildcard,
  key-ID precedence, other categories, denial reasons and lockpick guards.
- Existing `tests/DoorRequirementLookup.luau` passes in Edit and Play Client.
- Cloned the authored Door_Key_Demo Tool into the real player's Backpack in our
  temporary Play session. Before/after accepted it on server and replicated
  client; client rejected it after removal. One initial synchronous server
  post-destroy assertion failed; subsequent inspection found both versions
  rejecting the removed key. A fresh paired server lifecycle run agreed at every
  step: absent=false, pickup=true, synchronous removal=false, next heartbeat=false.
  No cache was involved. The temporary key/modules were cleaned up; Play stopped.
- Independent read-only review found no blocker. The pre-existing DoorClient
  decal/texture edit retains SHA256
  B21EDF67D71623E941FCF3D2952947B392160E59493564971DDCD1C28AD49D4D
  and is excluded from this commit.

`tests/DoorCandidateBenchmark.luau` constructs private full-module before/after
copies, reverting only the two candidate-query expressions for Before. Each case
alternates order over 12 pairs, discards 2 warmup pairs and measures 50 calls per
variant. Each recorded sample is the mean of 5 calls; values below are the median
of 10 samples in milliseconds per HasMatchingItem lookup, not frame times.
Every timed call asserts the same expected decision.

| Native Play Client case | Before ms | After ms |
| --- | ---: | ---: |
| Missing key, 3,000 synthetic geometry descendants | 1.52632 | 0.20640 |
| Linked key outside inventory, same fixture | 0.50510 | 0.12590 |
| Equipped character key, same fixture | 1.34914 | 0.16610 |
| Uncategorized name fallback, same fixture | 1.25486 | 1.14714 |
| Authored 01_Light_Push_And_Handle2/MainLeaf, real player | 0.91874 | 0.29470 |
| Authored 01_Light_Push_And_Handle/MainLeaf, real player | 0.90808 | 0.25620 |
| Authored 02_Double_Door/LeftLeaf, real player | 0.84676 | 0.21702 |
| Authored 02_Double_Door/RightLeaf, real player | 0.83690 | 0.20632 |
| Authored 03_Key_Locked_Breachable/MainLeaf, real player | 0.84412 | 0.23348 |

Tiny Edit inventories show selector overhead: roughly 0.012-0.015 ms before
versus 0.017-0.018 ms after. The category-nil path is unchanged; its small measured
variation is noise, not a separate optimization. Benchmark P95Ms is the maximum
of only ten five-call samples and must not be treated as a frame-time percentile.

The confirmed gain is lower overlapping client key-lookup CPU cost with large
inventory/character trees. No whole-frame FPS gain, zero-regression guarantee,
multiplayer soak-test result, or resolution of the reported G19 kill hitch / 825 ms
FastCluster geometry freeze is claimed. Visuals, combat and ragdoll code are untouched.
