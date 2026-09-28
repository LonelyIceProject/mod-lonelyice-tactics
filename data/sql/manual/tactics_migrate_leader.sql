-- Bot tactics: move the pre-round-2 bot settings to one leader in one go (tactics-round2-spec 4.3).
--
-- OPTIONAL and MANUAL. Not in db-characters on purpose: the server never applies it by itself.
-- Without it nothing is lost: the Lua scripts move a bot's old rows to the first player who has the bot in
-- the party after the update (store.lua, store.migrate). Run this only to give every bot's old rules to one
-- player at once (e.g. a single-player server), with the world server stopped or the bots logged out.
--
-- Settings that a player configures on a bot are now stored per (bot, leader) as "l<leaderGuid>_<key>"
-- (enabled, active, p1..p5, veto, ai; new: style, pull, aicfg). outfits / loot stay per bot, formation /
-- rti / the pull card stay per player.
--
-- Same rule as the Lua migration (store.lua, moveLegacy): a bot on which that leader already has any
-- "l<leader>_*" row of its own (written by the lazy migration or by a setting made after the update) is left
-- alone, its legacy rows stay where they are. A legacy row is deleted only once its namespaced copy exists.
--
-- Usage: set @leader to characters.guid of the player who made the rules, then run on the characters DB.
-- With @leader = 0 nothing happens.

SET @leader := 0;   -- characters.guid of the player who made the rules
SET @prefix := CONCAT('l', @leader, '_');

-- bots with legacy rows and no row of that leader yet
DROP TEMPORARY TABLE IF EXISTS `tactics_migrate_bots`;
CREATE TEMPORARY TABLE `tactics_migrate_bots` (`guid` INT UNSIGNED NOT NULL PRIMARY KEY);
INSERT INTO `tactics_migrate_bots` (`guid`)
  SELECT DISTINCT t.`guid` FROM `character_tactics` t
  WHERE t.`name` IN ('enabled', 'active', 'p1', 'p2', 'p3', 'p4', 'p5', 'veto', 'ai') AND @leader > 0
    AND NOT EXISTS (SELECT 1 FROM `character_tactics` o
                    WHERE o.`guid` = t.`guid` AND LEFT(o.`name`, CHAR_LENGTH(@prefix)) = @prefix);

-- copy every legacy row of those bots to that leader
INSERT IGNORE INTO `character_tactics` (`guid`, `name`, `data`, `updated`)
  SELECT t.`guid`, CONCAT(@prefix, t.`name`), t.`data`, t.`updated` FROM `character_tactics` t
  JOIN `tactics_migrate_bots` b ON b.`guid` = t.`guid`
  WHERE t.`name` IN ('enabled', 'active', 'p1', 'p2', 'p3', 'p4', 'p5', 'veto', 'ai');

-- bots outside a party read that leader's settings (store.leaderOf falls back to last_leader)
INSERT IGNORE INTO `character_tactics` (`guid`, `name`, `data`, `updated`)
  SELECT b.`guid`, 'last_leader', CAST(@leader AS CHAR), UNIX_TIMESTAMP() FROM `tactics_migrate_bots` b;

-- move, not copy: another leader must not inherit them. Only rows whose namespaced copy now exists with the
-- same data go.
DELETE t FROM `character_tactics` t
  JOIN `tactics_migrate_bots` b ON b.`guid` = t.`guid`
  JOIN `character_tactics` m ON m.`guid` = t.`guid` AND m.`name` = CONCAT(@prefix, t.`name`) AND m.`data` = t.`data`
  WHERE t.`name` IN ('enabled', 'active', 'p1', 'p2', 'p3', 'p4', 'p5', 'veto', 'ai');

DROP TEMPORARY TABLE IF EXISTS `tactics_migrate_bots`;
