# Project Status

## Verified in live testing

- Current Timewalking queue discovery
- DPS queueing
- Automatic proposal acceptance
- Entering a Timewalking dungeon
- LFG in-progress detection
- Tank role detection
- WardenGG tank object resolution
- Tank following
- Native path generation
- Direct movement fallback
- Tank target assistance
- Dungeon completion detection
- Teleport-out completion flow in earlier builds
- Automatic requeue
- Auto-role detection correctly reports Assassination as DAMAGER

## Implemented and under active testing

- Tank-leash recovery when combat causes separation
- Leave-instance-group completion exit
- Opportunistic corpse looting
- Healer/Tank auto-role queueing on non-DPS specs

## Latest fixed regression

v0.1.7 introduced:

```text
WGG:1475: attempt to call a nil value
```

The loot controller referenced a later-declared local helper. v0.1.8 removes that bad lexical dependency and checks combat state directly through `UnitAffectingCombat("player")`.

## Current priority

Improve in-dungeon reliability:

1. maintain tank leash during combat
2. recover after navigation stalls
3. loot without losing the group
4. handle dungeon-specific movement edge cases
5. add stronger death/recovery behavior
