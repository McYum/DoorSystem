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
| `LockSide` | `Front` or `Back` | Side allowed to lock/unlock and open a locked door. |
| `HideUnavailablePrompts` | `true` | Locally hides prompts the current player cannot use. |
| `OpenRequiresItem` | `true` | Also checks the item while the door is unlocked. |

Inventory lookup supports the authoritative `Player.Inventory` tree, linked
`ObjectValue`/Tool entries, and legacy Character/Backpack tools. A `DoorKey` with
`MasterKey=true` or `DoorKeyId="*"` opens every keyed door. Server scripts may call
`DoorService.CanPlayerAccess(...)` before custom interactions.

For old requirement modules, put a ModuleScript named `DoorRequirementChecker` or
`Checker` under the assembly/leaf (or `Requirements/Checker`). Existing `check` and
`checkserver` table APIs are supported. New checkers can expose
`Check(player, assembly, action)`.

## Melee breach integration

The melee adapter calls `DoorService.Kick` only for attack configurations with
`DoorImpact=true`. This reuses the door's own kick/breach durability, sound bank,
particle emitter, networking, and hinge impulse. Set `MeleeBreachEnabled=false` on an
assembly to opt that door out.
