# WorldSync

An addon for **World of Warcraft: Forever** that keeps you informed about layers and gets your group onto the same one.

- **Refresh prompt:** when the game offers a world refresh, WorldSync shows a clear prompt with the countdown and a **Refresh now** button. The button is disabled while you're in combat, flying or falling. Blizzard's own small message on the left of the screen still works too.
- **Auto-refresh (optional, off by default):** accept the refresh automatically once you're out of combat and on the ground.
- **Alerts:** a chat line when a refresh moves you to a new layer, and when your whole group is on one layer (both on by default), with optional sounds. Only you see them.

Blizzard's party frames already mark a group member who is on another layer: their frame fades and a phasing icon appears, with the reason on hover.

## Install

Install it from CurseForge or Wago, or by hand:

1. Close the game.
2. Download the latest zip from [Releases](https://github.com/reflectedreverb/WorldSync/releases) and put the `WorldSync` folder in `World of Warcraft/_forever_/Interface/AddOns/`.
3. Start the game and make sure WorldSync is ticked in the AddOns list.

## Use

| Command | What it does |
|---|---|
| `/ws` | Open the settings (also under Options → AddOns → WorldSync, or the AddOns button by the minimap) |
| `/ws demo` | Play a 20 second demo: the prompt and the messages, without moving you |
| `/ws diag` | Print a short status for bug reports (no names) |

## Settings

**World refresh**
- **Refresh prompt:** the clear prompt (on by default)
- **Auto-refresh when safe:** accept the refresh automatically once you're out of combat and on the ground (off by default)

**Alerts**
- **Message when moved / together:** a chat line when you move to a new layer, or when the whole group is on one layer
- **Sound when moved / together:** optional sounds (none by default)

If Refresh now doesn't move you, use Blizzard's message on the left of the screen instead.

## More addons

More addons by ReflectedReverb: <https://github.com/reflectedreverb>

## License

Copyright (C) 2026 ReflectedReverb.

WorldSync is free software under the [GNU General Public License v3.0](https://github.com/reflectedreverb/WorldSync/blob/main/LICENSE): you can use, change and share it, and any version you release must stay under the same license.
