-- mod-custom bot tactics: opaque per-character key/value text owned by the Lua scripts (lua_scripts/tactics).
-- Idempotent (re-applied on rehash).
CREATE TABLE IF NOT EXISTS `character_tactics` (
  `guid` INT UNSIGNED NOT NULL COMMENT 'characters.guid of the bot',
  `name` VARCHAR(32) NOT NULL COMMENT 'Lua-defined key',
  `data` MEDIUMTEXT NOT NULL COMMENT 'Lua-defined opaque text',
  `updated` INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'unix time of last write',
  PRIMARY KEY (`guid`, `name`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci COMMENT='mod-custom bot tactics; content owned by lua_scripts/tactics';
