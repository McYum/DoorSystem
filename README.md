# DoorSystem

DoorSystem doors are authored Models tagged `DoorSystemDoor`. Each assembly contains
`Leaves/<LeafRig>`, and each leaf rig contains `Hinge` plus a `Leaf` Model. The demo
assemblies in Studio are persistent instances; no runtime demo builder is required.

## Inventory keys and side locks

Set these attributes on the tagged assembly (or on one leaf rig to override it):

| Attribute | Example | Meaning |
| --- | --- | --- |
| `LockType` | `Key` | Locking/unlocking requires an inventory key. |
| `RequiredKeyId` | `DEMO_RANGE_A` | Must equal an inventory item's `DoorKeyId` or `KeyId`. |
| `RequiredItemCategory` | `DoorKey` | Optional category restriction; defaults to `DoorKey` for keyed doors. |
| `RequiredItemName` | `Door_Key_Demo` | Optional exact item/template name instead of, or in addition to, a key id. |
| `LockType` | `Side` | No item is required; access is restricted by side. |
| `LockType` | `Free` | No item is required; either side may lock/unlock. |
| `LockSide` | `Front`, `Back`, or `Both` | Side allowed to lock/unlock and open a locked door. `Both` also works with keyed doors. |
| `HideUnavailablePrompts` | `true` | Hides unavailable secondary controls; the main try/open prompt remains visible. |
| `OpenRequiresItem` | `true` | Also checks the item while the door is unlocked. |
| `PromptStackSpacing` | `58` | Vertical spacing between currently available door actions. |

The same flat keys can be returned from a `DoorConfig` ModuleScript directly under
the assembly or leaf. Attributes take precedence, so a designer can override one
module value without duplicating the rest. The persistent demos include this module.

For fully authored prompts, put `PromptAttachment` under a leaf's
`CollisionTemplate`, then add `DoorPrompt`, `LockPrompt`, or `KickPrompt`
`ProximityPrompt` instances beneath it. Their attachment position, keybinds,
distance, hold duration, object text, custom `Settings`/`Checker` children, and base
`UIOffset` are cloned into the smooth client proxy. DoorSystem adds
`PromptStackSpacing` to those base offsets. The main door prompt remains available
on a locked door so the player can try its handle; lock/unlock prompts are shown only
when that player has the required key or is on the permitted side.

Inventory lookup supports the authoritative `Player.Inventory` tree, linked
`ObjectValue`/Tool entries, and legacy Character/Backpack tools. A `DoorKey` with
`MasterKey=true` or `DoorKeyId="*"` opens every keyed door. Server scripts may call
`DoorService.CanPlayerAccess(...)` before custom interactions.

The Studio demo uses authored Tool instances at
`ServerScriptService.ItemTemplates.DoorKeys.Door_Key_Demo` and
`StarterPack.Door_Key_Demo`; it does not generate the key from a runtime script.

State attributes such as `DoorState`, `Open`, `Closed`, `Locked`, and `Health` are
runtime readbacks. For attribute-driven server commands, write `RequestedState`
(`Open`, `Closed`, `Locked`, or `Unlocked`), `RequestedLocked` (boolean), or
`RequestedHealth` (number). The easiest live Studio control is `DoorCommand`: enter
`Open`, `Close`, `Lock`, `Unlock`, `ToggleLock`, `Kick`, or `Reset`; it clears itself
after handling so the same command can be used repeatedly. Server code can alternatively call `DoorService.Open`,
`Close`, `SetLocked`, `SetState`, or `SetHealth` directly. Authored initial
`DoorState`/`Open`/`Closed`/`Locked` values are still honored when a door registers.
For a single stable entry point, synced server scripts can use:

```luau
local Doors = require(game.ServerScriptService.Scripts.DoorSystem.DoorService)
Doors.Command(workspace.MyDoor, "Open")
Doors.Command(workspace.MyDoor, "Lock")
Doors.Command(workspace.MyDoor, "SetHealth", 50)
```

`Doors.Control` is an alias of `Doors.Command`. Supported commands are `Open`,
`Close`, `Lock`, `Unlock`, `ToggleLock`, `Kick`, `SetHealth`, and `Reset`.

For old requirement modules, put a ModuleScript named `DoorRequirementChecker` or
`Checker` under the assembly/leaf (or `Requirements/Checker`). Existing `check` and
`checkserver` table APIs are supported. New checkers can expose
`Check(player, assembly, action)`.

## Melee breach integration

The melee adapter calls `DoorService.Kick` only for attack configurations with
`DoorImpact=true`. This reuses the door's own kick/breach durability, sound bank,
networking, and hinge impulse while retaining the melee system's normal impact audio
and VFX. DoorSystem does not add kick particles. Put a Sound or Folder of Sound
variants at `Sounds/KickAttempt` on the assembly/leaf to customize each door; the
Studio demos use the sounds from
`ReplicatedStorage.Miscs.MeleeSoundEffects.KickImpactSounds.Door`. Set
`MeleeBreachEnabled=false` on an assembly to opt that door out.

Walking contact now yields the local collision proxy as soon as validated body
contact is detected. At or above `SprintPushMinSpeed`, an unlocked closed door gets a
kick-like launch without taking durability damage. All sprint values can be changed
per door through attributes or `DoorConfig`. Sprint approaches use a longer swept
contact window and side padding, so diagonal runs that genuinely cross the slab are
accepted without treating near-tangential movement as an impact.

Both authored handles animate together by default (`HandleAnimateBothSides`) so the
movement is visible from either face. An optional `LockFrontMotor` and
`LockBackMotor` can drive authored thumbturn models between
`LockIndicatorUnlockedDeg` and `LockIndicatorLockedDeg`. The lockable Studio demos
include persistent `LockVisual` models with visible `LockFrontRoot` and
`LockBackRoot` thumbturns. Their `Motor6D` root points are named `LockFrontMotor`
and `LockBackMotor`. Each client springs those motors from the replicated `Locked`
state; late joiners receive the correct angle immediately, while state changes are
animated. The demos cover keyed both-side, keyless both-side, and restricted-side
locking.
