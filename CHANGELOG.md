# Changelog

## v0.2.2
- Added safer combat spacing so the follower does not remain directly on top of the tank.
- Default combat spacing is approximately 5.5 yd for DAMAGER and 10 yd for HEALER.
- Added WardenGG AreaTrigger scanning during combat.
- Added temporary movement out of detected dangerous ground-effect radii.
- Preserves the breadcrumb cursor while evading danger, then resumes the recorded route.
- Added `/twdanger` diagnostics.

## v0.2.1
- Added swimming/submerged recovery.
- Added pitch control toward 3D breadcrumbs while swimming.
- Added protected ascend/descend movement handling.
- Added short emergency ascent behavior when stalled in water.
- Added `/twwater` diagnostics.

## v0.2.0
- Removed Navigation Server as a requirement for active tank following.
- Changed tank following to direct breadcrumb movement.
- Tightened breadcrumb spacing and lookahead for better corner preservation.
- Retained the same breadcrumb during short movement stalls instead of chasing the tank's live position.

## v0.1.9
- Added tank breadcrumb tracing.
- Recorded the route the tank physically walked so combat separation could preserve corners and previous path history.
- Added corner detection and must-visit route points.
- Added `/twtrail` diagnostics.
- Initial breadcrumb implementation still depended on Warden Navigation Server for movement.

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
