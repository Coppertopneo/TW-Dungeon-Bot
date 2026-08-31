# Changelog

## v0.1.8
- Fixed loot-controller Lua scope error.
- Replaced early `playerInCombat()` call with direct `UnitAffectingCombat("player")` check.

## v0.1.7
- Added opportunistic corpse looting.
- Added `WGG.IsLootable()` scanning.
- Added `WGG.ObjectInteract()` loot interaction.
- Added `/twloot`.

## v0.1.6
- Changed completion exit to prefer leaving the instance group.
- Kept `LFGTeleport(true)` as a fallback.
- Preserved automatic requeue.

## v0.1.5
- Added combat tank-leash recovery.
- Added movement-first behavior when separated from tank.
- Reduced unnecessary healthy-path restarts.

## v0.1.4
- Added movement watchdog.
- Added short-range direct follow fallback.
- Added automatic specialization-role detection.

## v0.1.3
- Added stronger LFG dungeon-state detection using `GetLFGMode()`.
- Improved tank object resolution.
- Improved navigation map handling.
- Added `/twfollow`.

## v0.1.2
- Fixed protected-function compilation.
- This was the breakthrough that made actual queueing and proposal actions execute.

## v0.1.1
- Switched queueing toward Blizzard's current LFD UI path.
- Added stronger queue diagnostics.

## v0.1
- Initial prototype.
- Timewalking discovery, queue state, proposal handling, tank-follow architecture, completion/requeue skeleton.
