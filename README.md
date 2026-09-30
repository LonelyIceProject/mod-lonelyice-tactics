<p align="center"><img src="logo.png" width="128" alt="logo"></p>

# mod-lonelyice-tactics

Final Fantasy XII style *gambits* for the bots of your party. You give each bot an ordered list of rules
("ally below 50% health -> Flash Heal", "enemy casting -> Kick") and the bot follows the first rule that
matches; whatever the rules do not cover is left to the regular playerbots AI.

## Features

- **Gambits**: ordered rules of target, condition and action, unlocked with character level, stored per bot
  and per leader, with presets.
- **Party window** (in-game addon *BotTactics*, "Party"): bags, equipment, outfits, talents and glyphs, roles
  and behaviour switches, loot rules, quests, reputations, skills, vendor and buyback for every bot.
- **Orders and vetoes**: one-shot "cast this now", and per-spell rules for the class AI ("never" / "only on").
- **AI slider**: from plain playerbots behaviour to a utility layer that picks intents (interrupt, protect,
  save mana) on top of it.
- **Ability mirroring**: bots repeat what the leader does (pull, crowd control, mount) when asked to.
- All behaviour is written in Lua (`lua/tactics`); C++ only runs the scripts, exposes game facts and executes
  primitive commands. Edit a script and use `.tactics reload`.

## Requirements

- [LonelyIceProject/mod-playerbots](https://github.com/LonelyIceProject/mod-playerbots) (external hooks and
  loot strategy used by this module).
- LuaJIT 2.1 and [sol2](https://github.com/ThePhD/sol2): set `TACTICS_DEPS_DIR` to a folder with
  `luajit/{include,lib,bin}` and `sol2/include` (for example copied from vcpkg `luajit` and `sol2`).
## Install

This module is written for [LonelyIceProject/azerothcore-wotlk](https://github.com/LonelyIceProject/azerothcore-wotlk),
a fork of AzerothCore with runtime plugins, and builds in two ways.

**As a plugin** (the core built with `-DWITH_DYNAMIC_LINKING=ON`):

```
cmake -S azerothcore-wotlk -B build -DWITH_DYNAMIC_LINKING=ON -DWITH_PLAYERBOTS_HOOKS=ON ^
      -DAC_PLUGIN_ABI=lonelyice-ac-1 "-DAC_PLUGIN_SOURCE_DIRS=<path>/mod-playerbots;<path>/mod-lonelyice-tactics"
cmake --build build --config RelWithDebInfo
```

The plugin is laid out in `bin/<config>/plugins/lonelyice.tactics/`. Copy that folder into the server's `plugins` folder
(`PluginsDir` in worldserver.conf); [LonelyIce](https://github.com/LonelyIceProject/lonelyice) does this for you.

**As a classic static module**: clone into `modules/mod-lonelyice-tactics` of the core and rebuild.
## Configuration

`conf/mod_lonelyice_tactics.conf.dist`. `Tactics.Enable` switches the module; `Tactics.ScriptDir` points to
the Lua scripts (default: `lua/tactics` of the plugin, `lua_scripts/tactics` in a static build).

## Client addon

`client/addons/BotTactics` goes into the game's `Interface/AddOns`. LonelyIce installs it; by hand:
`tools/install_addon.ps1 -Client "<game folder>"`.
## Support

LonelyIce is free, with no ads and no paid features. If it is useful to you, you can
[buy me a coffee](https://buymeacoffee.com/darthgelum): it pays for the server, code signing and development time.

<a href="https://buymeacoffee.com/darthgelum"><img src=".github/buy-me-a-coffee.png" alt="Buy me a coffee" width="303"></a>

## License

GNU General Public License v2.0 or later, see [LICENSE](LICENSE). Part of the
[LonelyIce](https://github.com/LonelyIceProject/lonelyice) single-player project.
