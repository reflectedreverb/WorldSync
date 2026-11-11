# WorldSync

## v1.1.0

- **Lighter and simpler.** The group list is gone: Blizzard's party frames already mark a member who's on another layer. What's left costs almost nothing: about 50 times less work than v1.0.1 when a 40-player raid's group changes, and no group checks at all while you're solo (you still get the message when your layer changes).
- **"Layer" everywhere** instead of "world copy": "you've moved to a new layer." and "everyone in your group is on the same layer now."
- **`/ws` opens the settings.** `/ws demo` plays the prompt and both messages without moving you; `/ws diag` prints a short status for bug reports.
- **In the AddOns button by the minimap:** click for the settings; hover to see a refresh on offer, whether your group is on your layer, and your last layer change.
- **Safer.** If anything goes wrong, only that part switches off for the session, and Blizzard's own refresh message always works. Damaged saved settings no longer stop the addon.
- Auto-refresh tries once, then again after 15 seconds if the game hasn't moved you yet.
- The prompt sizes itself to its text, with shorter messages.
- Settings you never changed now follow the defaults; your own choices stay. The list's settings are removed from your saved settings.

## v1.0.1

- Now also on Wago. No changes in game.

## v1.0.0

First release. Keeps your group on the same layer in WoW: Forever.

- **Refresh prompt:** when the game offers a world refresh, a clear prompt with the countdown and a **Refresh now** button. It's disabled while you're in combat, flying or falling. Blizzard's own message still works too.
- **Group list** (optional, off by default): each member's zone and whether they're on your layer. Open it with `/ws`, or have it show when you join a group or someone is on another layer.
- **Auto-refresh** (optional, off by default): accepts the refresh once you're out of combat and on the ground.
- **Alerts** (optional): a chat line or a sound when you move to a new layer, or when the whole group is together.
- `/ws`, `/ws demo` (a 20 second demo with a made-up group), `/ws options`. Settings are also under Options → AddOns → WorldSync.
