# Project Status

## Current build

`v0.2.2-combat-safety`

Main file:

```text
_TW_DungeonBot_v0.2.2.lua
```

## Verified in live testing

- Current Timewalking queue discovery
- DPS queueing
- Automatic proposal acceptance
- Entering a Timewalking dungeon
- LFG in-progress detection
- Tank role detection
- WardenGG tank object resolution
- Ground tank following
- Automatic role detection correctly reporting Assassination as DAMAGER
- Tank target assistance
- Dungeon completion detection
- Teleport-out completion flow in earlier builds
- Automatic requeue after completion
- Direct breadcrumb movement functioning well enough to follow through normal dungeon sections before encountering special movement cases

## Problems observed during live testing

### Combat separation / corners

Earlier live-coordinate following could stop during heavy combat and fail to recover, especially when the tank rounded a corner or moved behind geometry.

This led to the breadcrumb architecture introduced in v0.1.9 and changed to direct breadcrumb movement in v0.2.0.

### Water / drops

During a dungeon run using the direct-breadcrumb follower, the group dropped through a hole into water. The player entered the water but did not recover movement automatically and had to be manually walked out before the bot was re-enabled.

v0.2.1 added dedicated swimming/submerged recovery for this case.

### Unsafe tank proximity

The follower was observed staying extremely close to the tank during combat, exposing the player to unnecessary tank-area damage and ground effects.

v0.2.2 increases combat spacing and adds generic AreaTrigger danger avoidance.

## Implemented and under active testing

- Direct breadcrumb corner handling across a larger variety of dungeon layouts
- Combat movement-stall recovery using saved breadcrumbs
- Water/submerged recovery from v0.2.1
- Emergency ascent when stalled in water
- DAMAGER combat spacing of about 5.5 yd
- HEALER combat spacing of about 10 yd
- WardenGG AreaTrigger danger detection
- Temporary AreaTrigger escape movement while preserving the breadcrumb route
- Opportunistic corpse looting
- Leave-instance-group completion exit
- Healer/Tank auto-role queueing on non-DPS specs

## Important architectural change

v0.2.0 and newer no longer require Warden Navigation Server for the active tank-follow system.

The controller records positions the tank physically walked through and then directly follows those saved world-coordinate breadcrumbs. Navigation Server-related helpers remain in the codebase for diagnostics, older fallback work, and possible future dungeon-specific features.

## Current movement priority

During an active dungeon the intended priority is approximately:

```text
completion handling
-> water/submerged recovery
-> dangerous AreaTrigger escape
-> tank leash / route recovery
-> breadcrumb following
-> opportunistic loot
-> ordinary close-range combat positioning
```

The exact route cursor is preserved when the bot temporarily leaves the trail to escape a detected danger area.

## Current risk areas

1. Some mechanics are not represented as WardenGG AreaTriggers.
2. Unknown or friendly AreaTriggers may require spell-ID ignore lists after live testing.
3. Drops, jumps, elevators, knockbacks, transports, and vehicles can require dungeon-specific handling.
4. External combat rotations can still compete with movement controls.
5. Water recovery is new and not yet validated across multiple dungeon water sections.
6. Death/ghost-run recovery is incomplete.
7. Tank-role dungeon traversal needs separate leader/route logic because follower mode assumes another party tank exists.

## Current priority

Improve in-dungeon survival and reliability without losing the tank route:

1. validate combat danger avoidance
2. validate water recovery
3. improve corner and obstacle recovery
4. identify false-positive AreaTrigger spell IDs
5. add stronger death/recovery behavior
