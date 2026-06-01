#!/usr/bin/perl
# ============================================================
# apcups_collector_mysql.pl — APC UPS data collector (MySQL)
# Copyright (C) 2024-2025 PlurumTech.com
# Licensed under GNU GPL v3 — https://www.gnu.org/licenses/gpl-3.0.html
# ============================================================
use strict;
use warnings;
use Fcntl qw(:flock);
use POSIX qw(strftime);
use DBI;

# Загружаем внешний конфиг если есть
do '/etc/apcups-monitor.conf' if -f '/etc/apcups-monitor.conf';

# ---------- Настройки ----------
my $logfile      = $apcups_logfile || '/var/log/apcups-collector.log';
my $lockfile     = '/var/run/apcups-collector.lock';
my $statusfile   = $apcups_statusfile || '/var/log/apcupsd.status';
my $shutdown_flag= $apcups_shutdown_flag || '/var/run/apcups-shutdown.flag';
my $threshold    = $apcups_shutdown_threshold || 15;

# MySQL connection
my $db_host      = $apcups_db_host || 'localhost';
my $db_port      = $apcups_db_port || 3306;
my $db_name      = $apcups_db_name || 'apcups_monitor';
my $db_user      = $apcups_db_user || 'apcups';
my $db_pass      = $apcups_db_pass || 'apcups';
my $db_table     = 'ups_data';

# RSync (optional)
my $remote_user  = $apcups_rsync_user;
my $remote_host  = $apcups_rsync_host;
my $remote_dir   = $apcups_rsync_dir;
# -----------------------------

sub log_msg {
    my ($msg) = @_;
    my $timestamp = strftime "%Y-%m-%d %H:%M:%S", localtime;
    open my $fh, '>>', $logfile or warn "Cannot open logfile: $!";
    print $fh "$timestamp - $msg\n" if $fh;
    close $fh if $fh;
}

# Блокировка
open my $lock_fh, '>', $lockfile or die "Cannot create lockfile: $!";
unless (flock($lock_fh, LOCK_EX|LOCK_NB)) {
    log_msg("Another instance is running, exit");
    exit 0;
}
log_msg("Script started");

# --- Парсим статус-файл ---
open my $fh, '<', $statusfile or die "Cannot open $statusfile: $!";
my %data;
while (<$fh>) {
    if (/^(SERIALNO|LINEV|LOADPCT|BCHARGE|TIMELEFT|ITEMP|BATTV|LINEFREQ|OUTPUTV|STATUS|MODEL)\s+:\s+(.+)/) {
        my ($key, $val) = ($1, $2);
        $val =~ s/\s+\S+$//;  # отрезаем единицы измерения (Volts, Percent, etc.)
        $data{$key} = $val;
    }
}
close $fh;

unless (defined $data{BCHARGE}) {
    log_msg("ERROR: BCHARGE not found in $statusfile");
    exit 1;
}

my $bcharge_raw = $data{BCHARGE};
$bcharge_raw =~ s/,/./;
my $bcharge_num = $bcharge_raw + 0;

# --- MySQL: авто-создание таблицы ---
log_msg("Connecting to MySQL $db_host:$db_port ...");
my $dsn = "DBI:mysql:host=$db_host;port=$db_port;dbname=$db_name";
my $dbh;
eval {
    local $SIG{ALRM} = sub { die "MySQL connect timeout\n" };
    alarm 10;
    $dbh = DBI->connect($dsn, $db_user, $db_pass, {
        RaiseError       => 1,
        AutoCommit       => 1,
        mysql_enable_utf8 => 1,
        mysql_connect_timeout => 5,
    });
    alarm 0;
};
if ($@) {
    alarm 0;
    log_msg("ERROR: Cannot connect to MySQL: $@");
    log_msg("Check: firewall? bind-address in /etc/my.cnf? SELECT user,host FROM mysql.user WHERE user='power'?");
    exit 1;
}
log_msg("MySQL connected");

# --- Авто-создание таблиц ---
my $tbl_hist = $db_table;
my $tbl_status = 'current_status';
eval {
    $dbh->do("CREATE TABLE IF NOT EXISTS $tbl_hist (
        id          BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        recorded_at DATETIME NOT NULL,
        serialno    VARCHAR(32),
        linev       DECIMAL(6,1),
        outputv     DECIMAL(6,1),
        loadpct     DECIMAL(5,1),
        bcharge     DECIMAL(5,1),
        INDEX idx_recorded_at (recorded_at)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci");

    $dbh->do("CREATE TABLE IF NOT EXISTS $tbl_status (
        id          TINYINT UNSIGNED PRIMARY KEY DEFAULT 1,
        updated_at  DATETIME NOT NULL,
        serialno    VARCHAR(32),
        model       VARCHAR(64),
        linev       DECIMAL(6,1),
        outputv     DECIMAL(6,1),
        loadpct     DECIMAL(5,1),
        bcharge     DECIMAL(5,1),
        timeleft    DECIMAL(5,1),
        itemp       DECIMAL(4,1),
        battv       DECIMAL(4,1),
        linefreq    DECIMAL(4,1),
        status      VARCHAR(32)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci");
};
if ($@) {
    log_msg("ERROR: Cannot create tables: $@");
    $dbh->disconnect;
    exit 1;
}

# --- INSERT в историю + UPSERT в текущий статус ---
my $now = strftime "%Y-%m-%d %H:%M:%S", localtime;
my $linev   = _num($data{LINEV})    // 0;
my $outputv = _num($data{OUTPUTV})  // 0;
my $loadpct = _num($data{LOADPCT})  // 0;
my $batttv = _num($data{BATTV})    // 0;
my $freq   = _num($data{LINEFREQ}) // 0;
my $tleft  = _num($data{TIMELEFT}) // 0;
my $temp   = _num($data{ITEMP})    // 0;
my $serial = $data{SERIALNO} // '';
my $st     = $data{STATUS}   // '';
my $model  = $data{MODEL}    // '';

eval {
    $dbh->do("INSERT INTO $tbl_hist (recorded_at, serialno, linev, outputv, loadpct, bcharge)
              VALUES (?,?,?,?,?,?)", undef,
              $now, $serial, $linev, $outputv, $loadpct, $bcharge_num);

    $dbh->do("INSERT INTO $tbl_status (id, updated_at, serialno, model, linev, outputv, loadpct,
              bcharge, timeleft, itemp, battv, linefreq, status)
              VALUES (1,?,?,?,?,?,?,?,?,?,?,?,?)
              ON DUPLICATE KEY UPDATE
              updated_at=VALUES(updated_at), serialno=VALUES(serialno), model=VALUES(model),
              linev=VALUES(linev), outputv=VALUES(outputv), loadpct=VALUES(loadpct),
              bcharge=VALUES(bcharge), timeleft=VALUES(timeleft), itemp=VALUES(itemp),
              battv=VALUES(battv), linefreq=VALUES(linefreq), status=VALUES(status)",
              undef,
              $now, $serial, $model, $linev, $outputv, $loadpct,
              $bcharge_num, $tleft, $temp, $batttv, $freq, $st);
};
if ($@) {
    log_msg("ERROR: MySQL query failed: $@");
} else {
    log_msg("Data saved: battery $bcharge_num%");
}
$dbh->disconnect;

# --- RSync (опционально) ---
if ($remote_host) {
    # Для обратной совместимости генерируем CSV и шлём его
    my $csv_line = "$now\t$data{SERIALNO}\t$data{LINEV}\t$bcharge_raw\t$data{LOADPCT}";
    my $csv_file = '/tmp/upsdata_mysql.csv';
    open my $cfh, '>', $csv_file or warn "Cannot write $csv_file: $!";
    print $cfh "$csv_line\n" if $cfh;
    close $cfh if $cfh;

    my $cmd = "rsync --log-file=$logfile $csv_file $remote_user\@$remote_host:$remote_dir/power.csv";
    system($cmd) == 0 or log_msg("RSync power.csv failed: $?");
    $cmd = "rsync --log-file=$logfile $statusfile $remote_user\@$remote_host:$remote_dir/";
    system($cmd) == 0 or log_msg("RSync status failed: $?");
    log_msg("RSync done");
}

# --- Логика выключения ---
if ($bcharge_num <= $threshold) {
    if (! -f $shutdown_flag) {
        open my $flag_fh, '>', $shutdown_flag or log_msg("Cannot create shutdown flag: $!");
        close $flag_fh;
        log_msg("Low battery ($bcharge_num% <= $threshold%) - initiating shutdown");

        my $shutdown_cmd;
        if ($bcharge_num <= 5) {
            $shutdown_cmd = "shutdown -h now";
            log_msg("Critical battery ($bcharge_num%) - shutdown immediately");
        } else {
            $shutdown_cmd = "shutdown -h +1";
            log_msg("Low battery ($bcharge_num%) - shutdown in 1 minute");
        }
        system($shutdown_cmd) == 0 or log_msg("Shutdown command failed: $?");
    } else {
        log_msg("Shutdown already requested, skip");
    }
} else {
    if (-f $shutdown_flag) {
        unlink $shutdown_flag;
        log_msg("Battery recovered ($bcharge_num% > $threshold%) - shutdown flag removed");
    }
}

close $lock_fh;
unlink $lockfile;
log_msg("Script finished");
exit 0;

# Вспомогательная функция: строка в число (запятая -> точка)
sub _num {
    my ($s) = @_;
    return undef unless defined $s;
    $s =~ s/,/./;
    return $s + 0;
}
