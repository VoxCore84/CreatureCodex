-- CreatureCodex: Multi-player aggregation table
-- Apply this to your characters database: mysql -u root -p characters < codex_aggregated.sql
CREATE TABLE IF NOT EXISTS `codex_aggregated` (
    `creature_entry` INT UNSIGNED NOT NULL,
    `spell_id` INT UNSIGNED NOT NULL,
    `cast_count` INT UNSIGNED NOT NULL DEFAULT 0,
    `last_reporter` VARCHAR(64) NOT NULL DEFAULT '',
    `last_seen` INT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (`creature_entry`, `spell_id`),
    KEY `idx_creature` (`creature_entry`),
    KEY `idx_spell` (`spell_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='CreatureCodex multi-player aggregated spell discoveries';
