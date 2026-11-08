# WorldSync

An addon for **World of Warcraft: Forever** that keeps your group on the same layer (world copy).

- **Refresh prompt:** when the game offers a world refresh, WorldSync shows a clear prompt with the countdown and a **Refresh now** button. The button is disabled while you're in combat, flying or falling. Blizzard's own small message on the left of the screen still works too.
- **Group list:** a small list of your group, showing each member's zone and whether they're in your world copy. The game only reports world copies for people in your zone, so meet up in the same zone to compare.
- **Alerts:** optional chat lines and sounds when you move to a new world copy, or when the whole group is together. Chat lines are only shown to you.

## Install

Install it from CurseForge, or by hand:

1. Close the game.
2. Download the latest zip from [Releases](../../releases) and put the `WorldSync` folder in `World of Warcraft/_forever_/Interface/AddOns/`.
3. Start the game and make sure WorldSync is ticked in the AddOns list.

## Use

| Command | What it does |
|---|---|
| `/ws` | Show the group list |
| `/ws demo` | Play a 20 second demo with a made-up group |
| `/ws options` | Open the settings (also under Options → AddOns → WorldSync) |

## Settings

**Group list**
- **Show the list:** never (default), on join or when apart, always in a group, or only when apart
- **Show after joining for:** how long the list stays after a join
- **Also for raid groups:** show it when joining raids too

**World refresh**
- **Refresh prompt:** the clear prompt (on by default)
- **Auto-refresh when safe:** accept the refresh automatically once you're out of combat and on the ground (off by default)

**Alerts**
- **Message when moved / together:** a chat line when you move to a new world copy, or when the whole group is together
- **Sound when moved / together:** optional sounds (none by default)

If Refresh now doesn't move you, use Blizzard's message on the left of the screen instead.

## License

Copyright (C) 2026 ReflectedReverb.

WorldSync is free software under the [GNU General Public License v3.0](LICENSE): you can use, change and share it, and any version you release must stay under the same license.
