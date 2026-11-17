# Momentum

**Version 1.0** · WoW Forever (client 1.60.1, interface 16001) · all classes

A compact combat HUD in three parts:

- **Resource bar**: energy, rage, mana, etc. with thresholds (change color, pulse).
- **Swing timer**: runs on the game's own swing event and corrects Slice and Dice haste.
- **Icon row**: procs while they are usable, then buffs, then cooldowns. Buffs keep running on their own clocks in combat.

Settings are stored per class: all characters of a class share them.

## Installation

1. Copy the `Momentum` folder to `World of Warcraft/_forever_/Interface/AddOns/`.
2. In game, type `/mom` to open the options.

## Commands

| Command                     | What it does                                                             |
| --------------------------- | ------------------------------------------------------------------------ |
| `/mom` or `/momentum`       | open or close the options                                                |
| `/mom unlock` / `/mom lock` | move the elements with the mouse                                         |
| `/mom add <name or ID>`     | add a buff to the whitelist                                              |
| `/mom remove <name or ID>`  | remove a buff from the whitelist                                         |
| `/mom proc <name or ID>`    | show a spell while it is usable (e.g. Riposte)                           |
| `/mom cd <name or ID>`      | show a spell while it is on cooldown (e.g. Shank)                        |
| `/mom auras`                | list your active buffs with their IDs (out of combat only)               |
| `/mom swingtest`            | run the swing bar for 8 seconds                                          |
| `/mom debug`                | diagnostics: shows how Momentum reads its values. Most useful in combat. |
| `/mom reset`                | reset this class to the defaults                                         |

Spell names, spell IDs and spell links all work as input. The name is stored, so every rank matches.

## Default look ("classic look")

The default look is rebuilt from an older addon:

- **Energy bar:** 198×21 with a 2 px black border and a beige gradient. It has a soft bright end, light lines on top and bottom, and Arial Narrow 19 text.
- **Swing bar:** 286×20, centred directly below, amber-brown, full while idle.
- **Threshold:** energy turns green from 50, blended in over 3 points.

_Options > General > Restore classic look_ brings this back at any time. Your lists and the positions of the energy bar and the icon row stay as they are.

## How it works

Forever runs on the Midnight engine, where many combat values are _secret_ for addons. Addons may pass them to the UI, but may not read or compare them. Momentum is built around that.

### Thresholds

The power value is secret, in and out of combat. The game itself evaluates the threshold: `UnitPowerPercent` with a curve returns an alpha, and Momentum only hands that alpha to `SetAlpha`.

- **Colour change:** from the threshold the bar is drawn in another colour. By default energy turns green from 50.
- **Pulse:** from the threshold a pulsing glow appears around the bar. By default rage pulses red from 80.

Thresholds are kept per resource. Values can be in points or in % of the maximum. _Preview (5 s)_ shows both.

### Swing timer

The swing bar runs on the native event `PLAYER_SWING(duration, type)`, exactly like Blizzard's built-in bar:

- every event restarts the timer for the duration it carries;
- a weapon change restarts a running swing;
- death or a loading screen clears it.

On top of that, Slice and Dice shortens the swing that is already in flight, and its end lengthens it again. Blizzard's bar gets that one swing wrong. Momentum corrects it from your cast. The speed factor starts at 1.2 for rank 1 and is then measured from the swing events (`/mom debug` shows the measured factors). Turn off Blizzard's own swing bar with _Options > General > Turn off_.

### Buffs in combat

In combat Forever refuses every aura query from addons. Momentum handles the two cases differently:

- **Out of combat:** the real buffs are shown. Momentum also learns each buff's duration from them, once per buff, and keeps it (stored per class).
- **In combat:** the row runs on Momentum's own clocks. Buffs that are already running when the fight starts carry over, and your own casts start or restart them. Buffs without a duration pause until the fight is over.

A buff you cast in combat gets a clock if Momentum knows its duration:

- **Slice and Dice** is calculated: (6 + 3 × combo points) seconds × the talent factor. The combo points are read from your target when the cast is sent. Forever keeps them on the target, so this stays correct when chaining mobs. The talent factor (Improved Slice and Dice) is learned from the real buff out of combat; until then it is assumed to be 1.
- **Built-in durations** work right away: Evasion, Adrenaline Rush, Blade Flurry and Sprint get 15 s, Ghostly Strike gets 7 s. A learned duration replaces them.
- **Any other buff** needs its duration learned first. For that, Momentum has to see the buff active out of combat once. It does not have to be cast out of combat: it is enough if it is still running after a fight. In mode "all but blacklist" only buffs you cast yourself are learned; in mode "whitelist only" every listed buff is.

_Limit:_ a buff that ends early in combat (cancelled or dispelled) keeps its clock until its time is up.

### Procs and cooldowns

These share the icon row with the buffs, in the order procs, buffs, cooldowns.

- **Procs** are shown while the game says the spell is usable. Riposte, Revenge, Counterattack, Mongoose Bite and Overpower also get a 5 s timer from the parry or dodge that opened them. Grey means usable, but not enough energy or rage yet.
- **Cooldowns** are shown while the spell is on a real cooldown; the global cooldown alone does not count. The time is the game's own cooldown text, like on the action bars.

Each class gets presets once (and again after `/mom reset`):

| Class   | Procs                        | Cooldowns |
| ------- | ---------------------------- | --------- |
| Rogue   | Riposte                      | Shank     |
| Warrior | Overpower, Revenge           | –         |
| Hunter  | Mongoose Bite, Counterattack | –         |

## Troubleshooting

- `/console scriptErrors 1` shows Lua errors, or install BugSack and BugGrabber.
- `/mom debug` lists how values were read: thresholds, auras, combo points and swing accuracy. It also shows the running clocks and recent errors.

## Development

The code is split into modules, loaded in this order (see `Momentum.toc`):

| File                  | Content                                                                    |
| --------------------- | -------------------------------------------------------------------------- |
| `Core.lua`            | namespace, settings and defaults, helpers, event and frame-update dispatch |
| `SettingsUpgrade.lua` | converts settings of earlier versions to the current names (once, on load) |
| `Gates.lua`           | thresholds on secret values (client-side curves)                           |
| `Look.lua`            | drawing helpers: position and dragging, border, glow, fill, spark, text    |
| `Resource.lua`        | resource bar and thresholds                                                |
| `Swing.lua`           | swing timer and Slice and Dice haste                                       |
| `Spells.lua`          | procs and cooldowns                                                        |
| `Buffs.lua`           | buffs, clocks and finisher durations                                       |
| `Row.lua`             | the icon row                                                               |
| `Commands.lua`        | applying settings, lists, reset, debug output, slash commands              |
| `Options.lua`         | options window (three fixed-width columns per page)                        |

Every function is documented with [LuaCATS](https://luals.github.io/wiki/annotations/) annotations.

## Changelog

### 1.0

- Code split into modules, every function documented with LuaCATS.
- New options layout in fixed columns: no overlapping or cut-off labels.
- "Tenths" time mode: tenths only below 10 seconds, so the text fits the icon.
- The swing bar and the icon row are drawn above the resource bar's glow.
- Long lists in the options can be scrolled with the mouse wheel.
- Descriptive names in the code and in the saved settings. Settings of earlier versions are converted automatically on the first login.