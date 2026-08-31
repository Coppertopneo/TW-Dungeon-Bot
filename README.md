# TW Dungeon Bot

Experimental World of Warcraft Retail Timewalking dungeon controller built for WardenGG.

## Current version

`v0.1.8-loot-scope-fix`

## Current feature set

- Detects the active Timewalking random-dungeon queue
- Detects current specialization role automatically
  - Tank -> Tank
  - Healer -> Healer
  - Damager -> DPS
- Queues through Blizzard's current Dungeon Finder UI path
- Automatically accepts LFG proposals
- Detects when the matched dungeon is in progress
- Detects the party tank
- Follows the tank using WardenGG navigation
- Uses a direct-follow fallback when native ground movement stalls
- Uses a tank-leash recovery system if combat causes separation
- Assists the tank's hostile target for an external combat rotation
- Opportunistically detects and interacts with nearby lootable corpses
- Detects dungeon completion
- Leaves the completed instance group
- Requeues automatically

## Requirements

- World of Warcraft Retail
- WardenGG Extended Lua Unlocker
- WardenGG Navigation Server
- Matching MMAP/VMAP navigation data
- An external combat rotation if automated ability use is desired

The default navigation server address used by the script is:

```text
127.0.0.1:47110
```

## Install

Download or copy:

```text
_TW_DungeonBot_v0.1.8.lua
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

Print the available random Dungeon Finder entries and selected Timewalking queue.

```text
/twstate
```

Print queue, proposal, dungeon, navigation, and tank state.

```text
/twqueue
```

Print Dungeon Finder queue diagnostics.

```text
/twfollow
```

Print tank-follow and navigation diagnostics.

```text
/twloot
```

Print nearest-lootable-corpse diagnostics.

## Current behavior

The tested loop is:

```text
find Timewalking queue
-> choose role from current spec
-> queue
-> accept proposal
-> enter dungeon
-> detect/follow tank
-> assist combat target
-> opportunistically loot
-> detect dungeon completion
-> leave instance group
-> requeue
```

## Known limitations

This is still experimental.

- Dungeon-specific mechanics are not explicitly scripted.
- Tank skips, jumps, teleports, elevators, vehicles, and unusual geometry can still break following.
- Combat and movement can compete for control depending on the external rotation.
- Looting is intentionally conservative so it does not abandon the tank.
- Death recovery is not a complete unattended ghost-run system.
- Navigation quality depends heavily on available MMAP/VMAP data.
- Some dungeon endpoints or moving targets may produce invalid or short-lived paths.

## Account warning

Automated unattended gameplay can violate Blizzard's rules and may put an account at risk.

## Status

See [docs/STATUS.md](docs/STATUS.md) for the current tested state.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).
