# Stream Deck Bridge for Project Zomboid

The Project Zomboid half of [Zomboid Deck](https://teatimeservers.ca/plugins/zomboid-deck), a Stream Deck plugin. It
is a small client-side Build 42 mod: once a second it writes what your survivor can see about themselves to
`Zomboid\Lua\StreamDeck\state.json`, which the plugin draws its keys from, and it runs the few key presses the plugin
leaves in `Zomboid\Lua\StreamDeck\command.json`.

It never changes a stat or spawns anything, never writes a zombie infection the game's Health tab does not show, opens
no network connection and only works for the local player. This repository is
here so you can see exactly what it does: it is all in one file,
[`StreamDeckBridge.lua`](StreamDeckBridge/42/media/lua/client/StreamDeckBridge.lua).

## What it reads

- Overall health; how many body parts are bitten, scratched or bleeding.
- The game's Health tab, rule for rule from `ISHealthPanel.lua`: the Overall Body Status line, and for each body part
  the lines the tab lists (scratched, laceration, deep wound, bitten, bleeding, fracture, burned, a lodged bullet or
  glass, an infected wound, pain, muscle strain, bandaged, stitched, splinted), in the game's words and colours. Grades
  that depend on your Doctor skill follow it, as in the game.
- The moodles the game is showing, with their level, whether they are good or bad and the game's own name for them.
- The stats those moodles are made from (hunger, thirst, fatigue, endurance, stress, panic, boredom, unhappiness),
  never infection, zombie fever or sickness.
- The time, date, game speed and season; the weather where you stand (temperature, rain, snow, fog, cloud, wind,
  thunder).
- What is in your hands: name, condition, sharpness, and for guns the ammo, chamber, magazine and jams; lights and
  their battery.
- Your load against what you can carry; hours survived and kills; zombies you can see and zombies chasing you.
- Indoors or out, the light on your square, and whether the power and mains water are still on.
- In single player, how long the power and the mains water have left, worked out with the game's own shutoff rule
  (ElecShutModifier and WaterShutModifier against the world's age), including "Instant" and never. On a server it
  leaves this out and writes only whether they are on, since knowing the day there would be an advantage.
- The car you are in: speed, gear, fuel, engine running and its condition, headlights, and whether you are driving.
- The game's Mechanics window for the vehicle you are in, rule for rule from `ISVehicleMechanics.lua`: the vehicle's name
  and type, its Overall Condition, weight and engine power, and every part by category with its condition in the
  window's colours ("Missing" for a part that has been taken off, and the battery's and gas tank's "% Remaining"),
  plus which parts the car overlay draws. The window's debug-mode lines are left out.
- Whether you are sitting or asleep, the game is paused, or you are at the main menu.

## What it can do

Each one is the game's own action, checked the way the game's own key or menu checks it, and refused while the game
is paused:

| Command | Does what the game does for |
| --- | --- |
| `sit` | Sit on Ground (sits down, or gets up) |
| `light` | Equip/Turn On/Off Light Source, on foot |
| `headlights` | the vehicle menu's headlights switch, driver only |
| `engine` | Start Vehicle Engine (starts or stops it), driver only |
| `cancel` | clears your queue of timed actions, without opening the pause menu |

A press is run once (each carries an id) and dropped if it is more than five seconds old.

## Installing

The Zomboid Deck plugin installs it for you: **Install the mod** in any Zomboid Deck key's settings, with the game
closed. By hand:

1. Close Project Zomboid.
2. Copy the `StreamDeckBridge` folder into `C:\Users\<you>\Zomboid\mods`, so you have
   `Zomboid\mods\StreamDeckBridge\42\mod.info`.
3. Start the game, switch on **Stream Deck Bridge** in **Mods** (and in a save's own mod list for a save you already
   have), and load a save.

The game's `Zomboid\console.txt` gets one `[StreamDeckBridge]` line when the mod loads and one when it first writes
the state file, so you can tell it is running.

Needs Build 42.20 or newer; checked against 42.21.

## The state file

JSON, rewritten whole once a second in real time, so it keeps up at any game speed and while paused. `protocol` is the
file's format version and `state` is `menu`, `loading`, `ingame`, `paused` or `dead`. Stats, fuel and sharpness are
fractions from 0 to 1. Anything that could not be read is left out, so a game update that renames one method costs
one field, not the file. Lua mods cannot rename files in the Zomboid folder, so each write ends with `"end": true` and
the plugin ignores a file that does not.

## Licence

MIT, see `LICENSE`. Zomboid Deck is an unofficial fan project, not affiliated with or endorsed by The Indie Stone.
Project Zomboid is a trademark of The Indie Stone.
