# TW Dungeon Bot

Experimental World of Warcraft Retail Timewalking dungeon controller built for WardenGG.

## Current version

`v0.2.2-combat-safety`

Main source:

```text
_TW_DungeonBot_v0.2.2.lua
```

The older `v0.1.8` file may remain in the repository as a rollback build while the newer movement system is tested.

## Current feature set

- Detects the active Timewalking random-dungeon queue
- Detects the current specialization role automatically
  - Tank -> Tank
  - Healer -> Healer
  - Damager -> DPS
- Queues through Blizzard's Dungeon Finder flow
- Automatically accepts LFG proposals
- Detects when the matched dungeon is in progress
- Detects the party tank
- Records the tank's movement as a breadcrumb trail
- Follows the recorded breadcrumb route instead of constantly chasing the tank's live position
- Preserves corners so combat stalls are less likely to cause wall-cutting shortcuts
- Tank following does **not** require Warden Navigation Server in the current direct-breadcrumb mode
- Retains the route while combat temporarily prevents movement
- Includes tank-leash recovery if the group starts getting away
- Includes water/submerged recovery with pitch and ascend/descend controls
- Maintains safer combat spacing instead of standing directly on the tank
- Detects nearby WardenGG AreaTriggers during combat and attempts to move out of dangerous ground effects
- Assists the tank's hostile target for an external combat rotation
- Opportunistically detects and interacts with nearby lootable corpses
- Detects dungeon completion
- Leaves the completed instance group
- Requeues automatically

## Requirements

- World of Warcraft Retail
- WardenGG Extended Lua Unlocker
- An external combat rotation if automated class/spec ability use is desired

### Navigation Server

Warden Navigation Server is **not required for the active v0.2.2 tank-follow system**. The follower records positions the tank physically walked through and directly moves through those breadcrumbs.

Some older navigation helpers remain in the source for diagnostics, rollback work, and future dungeon-specific movement handling.

## Install

Download or copy:

```text
_TW_DungeonBot_v0.2.2.lua
```

into the WardenGG script folder, for example:

```text
C:\WGG\
```

Only one TW Dungeon Bot controller should be loaded at a time.

## Commands

```text
/twbot
```
Toggle the controller.

```text
/twscan
```
Print available random Dungeon Finder entries and the selected Timewalking queue.

```text
/twstate
```
Print current queue/dungeon/controller state.

```text
/twqueue
```
Print Dungeon Finder queue diagnostics.

```text
/twfollow
```
Print tank-follow diagnostics.

```text
/twtrail
```
Print breadcrumb-trail state, cursor, target point, and movement information.

```text
/twloot
```
Print nearest-lootable-corpse diagnostics.

```text
/twwater
```
Print swimming/submerged recovery state and vertical breadcrumb information.

```text
/twdanger
```
Print combat spacing and nearby AreaTrigger danger information.

## Current behavior

```text
find Timewalking queue
-> choose role from current spec
-> queue
-> accept proposal
-> enter dungeon
-> identify tank
-> continuously record tank breadcrumbs
-> follow saved route
-> recover after combat movement stalls
-> recover through water/swimming sections
-> maintain combat spacing
-> evade detected dangerous AreaTriggers
-> assist external combat rotation
-> opportunistically loot
-> detect dungeon completion
-> leave instance group
-> requeue
```

## Movement design

The newer follower intentionally avoids treating the tank's current coordinates as the route.

Instead:

```text
Tank: A -> B -> C -> CORNER -> D -> E
Bot:  A -> B -> C -> CORNER -> D -> E
```

If combat holds the player back, the saved breadcrumbs remain queued while the tank continues recording points ahead. When movement becomes available again, the controller resumes the saved route rather than attempting a straight-line shortcut through walls or around the wrong side of a corner.

## Combat safety

Default combat spacing is currently approximately:

```text
DAMAGER: 5.5 yd from tank
HEALER:  10 yd from tank
```

During combat the bot also scans WardenGG AreaTrigger objects. When it believes the player is inside a hostile or unknown ground-effect radius, it temporarily moves outward, then resumes the same breadcrumb route after clearing the area.

AreaTrigger classification is still experimental. Some mechanics may require spell-specific allow/ignore lists after live testing.

## Known limitations

This project is still experimental.

- Dungeon-specific mechanics are not fully scripted
- Jumps, teleports, elevators, vehicles, knockbacks, scripted transports, and unusual geometry can still need special handling
- Water recovery is newly implemented and needs broader dungeon testing
- Ground-effect avoidance only covers mechanics represented as detectable AreaTriggers
- Friendly/hostile AreaTrigger classification may produce false positives until specific spell IDs are observed in live runs
- External combat rotations can still compete with movement controls
- Looting is intentionally conservative so it does not abandon the group
- Death recovery is not yet a complete unattended ghost-run system
- Tank-role dungeon traversal is not equivalent to follower mode because there may be no other tank to follow

## Account warning

Automated unattended gameplay can violate Blizzard's rules and may put an account at risk.

## Status

See [docs/STATUS.md](docs/STATUS.md) for the current tested state.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
