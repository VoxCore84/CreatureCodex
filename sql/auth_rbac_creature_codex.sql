-- CreatureCodex: RBAC permission for .codex GM command
INSERT IGNORE INTO `rbac_permissions` (`id`, `name`) VALUES (3012, 'Command: codex');
-- Link to GM role (role 193 = GM commands)
INSERT IGNORE INTO `rbac_linked_permissions` (`id`, `linkedId`) VALUES (193, 3012);
