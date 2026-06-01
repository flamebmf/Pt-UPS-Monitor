-- ============================================================
-- apcups_ui.sql — APC UPS Monitor database schema
-- Copyright (C) 2024-2025 PlurumTech.com
-- Licensed under GNU GPL v3 — https://www.gnu.org/licenses/gpl-3.0.html
-- ============================================================

-- UPS monitoring database schema
-- DB and user created by install.sh

CREATE TABLE IF NOT EXISTS ups_data (
    id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
    recorded_at DATETIME NOT NULL COMMENT 'Время замера',
    serialno    VARCHAR(32)              COMMENT 'Серийный номер UPS',
    model       VARCHAR(64)              COMMENT 'Модель UPS',
    linev       DECIMAL(6,1)             COMMENT 'Входное напряжение, V',
    outputv     DECIMAL(6,1)             COMMENT 'Выходное напряжение, V',
    loadpct     DECIMAL(5,1)             COMMENT 'Нагрузка, %',
    bcharge     DECIMAL(5,1)             COMMENT 'Заряд батареи, %',
    timeleft    DECIMAL(5,1)             COMMENT 'Осталось времени, мин',
    itemp       DECIMAL(4,1)             COMMENT 'Температура UPS, C',
    battv       DECIMAL(4,1)             COMMENT 'Напряжение батареи, V',
    linefreq    DECIMAL(4,1)             COMMENT 'Частота сети, Hz',
    status      VARCHAR(32)              COMMENT 'Статус (ONLINE/ONBATT/etc)',
    created_at  TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    INDEX idx_recorded_at (recorded_at),
    INDEX idx_serialno (serialno),
    INDEX idx_status (status)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='История параметров APC UPS';

-- Текущий статус UPS (одна строка, обновляется каждым запуском collector-а)
CREATE TABLE IF NOT EXISTS current_status (
    id          TINYINT UNSIGNED PRIMARY KEY DEFAULT 1,
    updated_at  DATETIME NOT NULL COMMENT 'Время последнего обновления',
    serialno    VARCHAR(32)              COMMENT 'Серийный номер UPS',
    model       VARCHAR(64)              COMMENT 'Модель UPS',
    linev       DECIMAL(6,1)             COMMENT 'Входное напряжение, V',
    outputv     DECIMAL(6,1)             COMMENT 'Выходное напряжение, V',
    loadpct     DECIMAL(5,1)             COMMENT 'Нагрузка, %',
    bcharge     DECIMAL(5,1)             COMMENT 'Заряд батареи, %',
    timeleft    DECIMAL(5,1)             COMMENT 'Осталось времени, мин',
    itemp       DECIMAL(4,1)             COMMENT 'Температура UPS, C',
    battv       DECIMAL(4,1)             COMMENT 'Напряжение батареи, V',
    linefreq    DECIMAL(4,1)             COMMENT 'Частота сети, Hz',
    status      VARCHAR(32)              COMMENT 'Статус (ONLINE/ONBATT/etc)'
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Текущий статус UPS';
