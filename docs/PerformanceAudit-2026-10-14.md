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
