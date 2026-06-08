#!/usr/bin/env bash
# ============================================================
# install.sh — APC UPS Monitor installer (RHEL / Debian-Ubuntu)
# Copyright (C) 2024-2025 PlurumTech.com
# Licensed under GNU GPL v3 — https://www.gnu.org/licenses/gpl-3.0.html
# ============================================================
set -euo pipefail

# ============================================================
# APC UPS Monitor Installer — RHEL / Debian-Ubuntu
# ============================================================
VERSION="1.0"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF_FILE="/etc/apcups-monitor.conf"

# --- colours ---
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; NC=$'\033[0m'; BOLD=$'\033[1m'

info()  { echo -e "${GREEN}[*]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[X]${NC} $*"; }
title() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }
ask()   { echo -en "${CYAN}[?]${NC} $1 [Y/n] " >&2; read -r r; [[ "${r:-Y}" =~ ^[Nn] ]] && return 1 || return 0; }
get()   { echo -en "${CYAN}[?]${NC} $1: " >&2; read -r r; [ -n "$r" ] && echo "$r"; [ -n "$r" ]; }
get_silent() { echo -en "${CYAN}[?]${NC} $1: " >&2; read -r -s r; echo >&2; [ -n "$r" ] && echo "$r"; [ -n "$r" ]; }

# ============================================================
# OS detection + package manager abstraction
# ============================================================
detect_os() {
    title "Detecting OS"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_NAME="$PRETTY_NAME"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="rhel"
        OS_NAME="$(cat /etc/redhat-release)"
    else
        err "Cannot detect OS"; exit 1
    fi
    info "OS: $OS_NAME"

    case "$OS_ID" in
        rhel|centos|fedora|rocky|almalinux|ol|redhat*)
            PKGMGR="dnf"
            APACHE_PKG="httpd"
            APACHE_SVC="httpd"
            APACHE_CONF_D="/etc/httpd/conf.d"
            CRON_FILE="/etc/cron.d/apcups-monitor"
            ;;
        debian|ubuntu|linuxmint)
            PKGMGR="apt-get"
            APACHE_PKG="apache2"
            APACHE_SVC="apache2"
            APACHE_CONF_D="/etc/apache2/conf-available"
            ;;
        *)
            err "Unsupported OS: $OS_ID"; exit 1
            ;;
    esac
    info "Package manager: $PKGMGR  |  Apache: $APACHE_SVC"
}

# ============================================================
# Read apcupsd configuration
# ============================================================
read_apcupsd_conf() {
    title "Reading apcupsd configuration"
    local apc_conf=""
    for f in /etc/apcupsd/apcupsd.conf /etc/apcupsd.conf; do
        [ -f "$f" ] && { apc_conf="$f"; break; }
    done
    if [ -z "$apc_conf" ]; then
        warn "apcupsd.conf not found in standard locations"
        A_STATUSFILE="/var/log/apcupsd.status"
        A_STATTIME=60
    else
        info "Found: $apc_conf"
        A_STATUSFILE=$(awk -F'[[:space:]]+' '/^STATFILE/ {print $2; exit}' "$apc_conf")
        A_STATTIME=$(awk -F'[[:space:]]+' '/^STATTIME/ {print $2; exit}' "$apc_conf")
        [ -z "$A_STATUSFILE" ] && A_STATUSFILE="/var/log/apcupsd.status"
        [ -z "$A_STATTIME" ]    && A_STATTIME=60
    fi
    info "STATFILE = $A_STATUSFILE"
    info "STATTIME = $A_STATTIME sec"
}

# ============================================================
# Check / install packages
# ============================================================
check_deps() {
    title "Checking dependencies"
    local missing=()
    local pkgs_perl=("perl" "perl-DBI" "perl-DBD-MySQL")
    local pkgs_deb=("perl" "libdbi-perl" "libdbd-mysql-perl")

    command -v mysql    >/dev/null 2>&1 || { warn "mysql client missing"; apt_or_dnf_install mysql-client mariadb; }
    command -v apcupsd  >/dev/null 2>&1 || warn "apcupsd not found in PATH"
    command -v rsync    >/dev/null 2>&1 || missing+=("rsync")

    # Perl modules check
    perl -e 'use DBI'       2>/dev/null || {
        case "$OS_ID" in debian|ubuntu) missing+=("libdbi-perl") ;; *) missing+=("perl-DBI") ;; esac
    }
    perl -e 'use DBD::mysql' 2>/dev/null || {
        case "$OS_ID" in debian|ubuntu) missing+=("libdbd-mysql-perl") ;; *) missing+=("perl-DBD-MySQL") ;; esac
    }

    # Apache
    if ! command -v httpd >/dev/null 2>&1 && ! command -v apache2 >/dev/null 2>&1; then
        warn "Apache not found in PATH (CGI needs it)"
        ask "Install Apache ($APACHE_PKG)?" && missing+=("$APACHE_PKG")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        info "Installing: ${missing[*]}"
        if [ "$PKGMGR" = "dnf" ]; then
            dnf install -y "${missing[@]}"
        else
            apt-get update -qq && apt-get install -y "${missing[@]}"
        fi
    fi
    info "Dependencies OK"
}

apt_or_dnf_install() {
    local deb_pkg="$1" rpm_pkg="$2"
    if [ "$PKGMGR" = "dnf" ]; then
        dnf install -y "$rpm_pkg"
    else
        apt-get install -y "$deb_pkg"
    fi
}

# ============================================================
# Verify apcupsd
# ============================================================
verify_apcupsd() {
    title "Verifying apcupsd"
    if ! systemctl is-active --quiet apcupsd 2>/dev/null; then
        warn "apcupsd service is not running"
        if ask "Install and configure apcupsd?"; then
            apt_or_dnf_install apcupsd apcupsd
            systemctl enable --now apcupsd 2>/dev/null || true
        fi
    else
        info "apcupsd service is active"
    fi

    if [ -f "$A_STATUSFILE" ]; then
        info "Status file exists: $A_STATUSFILE ($(wc -l < "$A_STATUSFILE") lines)"
    else
        warn "Status file $A_STATUSFILE does not exist yet (will appear on first STATTIME tick: ${A_STATTIME}s)"
    fi
}

# ============================================================
# MySQL setup
# ============================================================
setup_mysql() {
    title "MySQL / MariaDB setup"
    if ! systemctl is-active --quiet mysql 2>/dev/null && \
       ! systemctl is-active --quiet mariadb 2>/dev/null && \
       ! systemctl is-active --quiet mysqld 2>/dev/null; then
        warn "No local MySQL/MariaDB service running"
        if ask "Install MariaDB server locally?"; then
            if [ "$PKGMGR" = "dnf" ]; then
                info "Installing mariadb-server (may prompt for GPG key)..."
                dnf install -y mariadb-server --nogpgcheck || {
                    err "mariadb-server install failed"
                    err "Try manually: dnf install mariadb-server"
                    exit 1
                }
                info "Starting mariadb service..."
                systemctl enable --now mariadb 2>/dev/null || {
                    err "Failed to start mariadb"
                    err "Try manually: systemctl enable --now mariadb"
                    exit 1
                }
                # Wait for socket
                for i in $(seq 1 10); do
                    [ -S /var/lib/mysql/mysql.sock ] || [ -S /run/mariadb/mysql.sock ] && break
                    sleep 1
                done
            else
                info "Installing mariadb-server..."
                DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server
                systemctl enable --now mariadb 2>/dev/null || true
            fi
            info "MariaDB installed. Run mysql_secure_installation if needed."
        fi
    else
        for s in mysql mariadb mysqld; do
            systemctl is-active --quiet "$s" 2>/dev/null && { info "Service $s is active"; break; }
        done
    fi
}

# ============================================================
# Prompt for all config values
# ============================================================
prompt_config() {
    title "Configuration"
    DEST_DIR=$(get "Install scripts to [/usr/local/lib/apcups-monitor]" || echo "/usr/local/lib/apcups-monitor")
    SHUTDOWN_THRESHOLD=$(get "Shutdown battery threshold % [15]" || echo "15")
    LOGFILE="/var/log/apcups-collector.log"

    DB_HOST=$(get "MySQL host"               || echo "localhost")
    DB_PORT=$(get "MySQL port [3306]"        || echo "3306")
    DB_NAME=$(get "Database name [apcups_monitor]" || echo "apcups_monitor")
    DB_USER=$(get "DB user [apcups]"          || echo "apcups")
    DB_PASS=$(get "DB password [apcups]"       || echo "apcups")
    MYSQL_ROOT_USER=$(get "MySQL admin user [root]" || echo "root")
    MYSQL_ROOT_PASS=$(get_silent "MySQL admin password (empty if none)" || echo "")
}

# ============================================================
# Existing installation detection
# ============================================================
EX_CONF=0; EX_SCRIPTS=0; EX_VHOST=0; EX_CRON=0; EX_DB=0
REINSTALL=0
check_existing() {
    title "Checking existing installation"
    local any=0
    [ -f "$CONF_FILE" ]    && { warn "Config exists:    $CONF_FILE";    EX_CONF=1;    any=1; }
    [ -d "$DEST_DIR" ]     && { warn "Scripts in:       $DEST_DIR";    EX_SCRIPTS=1; any=1; }
    [ -f "$APACHE_CONF_D/apcups-monitor.conf" ] && { warn "Apache vhost:    $APACHE_CONF_D/apcups-monitor.conf"; EX_VHOST=1; any=1; }
    [ -f "$CRON_FILE" ]    && { warn "Cron:             $CRON_FILE";   EX_CRON=1;    any=1; }
    local mc="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER"
    [ -n "$DB_PASS" ] && mc="$mc -p$DB_PASS"
    echo "SELECT 1 FROM ups_data LIMIT 1;" | $mc "$DB_NAME" >/dev/null 2>&1 && { warn "DB tables exist:  $DB_NAME.ups_data"; EX_DB=1; any=1; }

    if [ "$any" -eq 1 ]; then
        echo
        if ask "Reinstall existing components? (No = keep existing, install missing only)"; then
            REINSTALL=1
        else
            info "Keeping existing components, will install missing ones only"
        fi
    else
        info "No previous installation found"
    fi
}

# ============================================================
# DB — create schema
# ============================================================
setup_db() {
    title "Database setup"
    if [ "$EX_DB" -eq 1 ]; then
        info "DB tables already exist: $DB_NAME.ups_data (keeping)"
        return
    fi

    # какой mysql используем
    if ! command -v mysql >/dev/null 2>&1; then
        err "mysql client not found — install mariadb package"
        exit 1
    fi

    # пробуем сокет, затем TCP
    local mysql_cmd="mysql -h $DB_HOST -P $DB_PORT -u $MYSQL_ROOT_USER --connect-timeout=3"
    for s in /var/lib/mysql/mysql.sock /run/mariadb/mysql.sock /run/mysqld/mysqld.sock; do
        if [ -S "$s" ]; then
            mysql_cmd="mysql -S $s -u $MYSQL_ROOT_USER --connect-timeout=3"
            info "Using socket: $s"
            break
        fi
    done
    [ -n "$MYSQL_ROOT_PASS" ] && mysql_cmd="$mysql_cmd -p$MYSQL_ROOT_PASS"

    # Шаг 1: создать БД
    info "Creating database '$DB_NAME'..."
    if ! echo "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" | $mysql_cmd; then
        err "Failed to create database — see error above"
        exit 1
    fi

    # Шаг 2: создать пользователя + права
    info "Creating user '$DB_USER' and granting privileges..."
    $mysql_cmd <<-EOSQL
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
EOSQL

    # Шаг 3: создать таблицы
    info "Creating tables..."
    if ! $mysql_cmd "$DB_NAME" < "$SCRIPT_DIR/apcups_ui.sql"; then
        err "Failed to create tables"
        err "Check: $SCRIPT_DIR/apcups_ui.sql exists and is valid SQL"
        exit 1
    fi

    info "Database ready: $DB_NAME@$DB_HOST:$DB_PORT (user: $DB_USER)"
}

# ============================================================
# Generate config file
# ============================================================
generate_config() {
    title "Generating $CONF_FILE"
    if [ "$EX_CONF" -eq 1 ]; then
        if [ "$REINSTALL" -eq 1 ] && ! ask "Config already exists — overwrite?"; then
            info "Keeping existing config: $CONF_FILE"
            return
        elif [ "$REINSTALL" -eq 0 ]; then
            info "Config already exists: $CONF_FILE (keeping)"
            return
        fi
    fi

    cat > "$CONF_FILE" <<-EOCONF
# APC UPS Monitor configuration — generated $(date)
\$apcups_statusfile        = '$A_STATUSFILE';
\$apcups_stattime           = '$A_STATTIME';
\$apcups_shutdown_threshold = $SHUTDOWN_THRESHOLD;
\$apcups_shutdown_flag      = '/var/run/apcups-shutdown.flag';
\$apcups_logfile            = '$LOGFILE';

\$apcups_db_host = '$DB_HOST';
\$apcups_db_port = $DB_PORT;
\$apcups_db_name = '$DB_NAME';
\$apcups_db_user = '$DB_USER';
\$apcups_db_pass = '$DB_PASS';
1;
EOCONF
    info "Config written: $CONF_FILE"
}

# ============================================================
# Install scripts
# ============================================================
install_scripts() {
    title "Installing scripts"
    if [ "$EX_SCRIPTS" -eq 1 ]; then
        if [ "$REINSTALL" -eq 1 ] && ! ask "Scripts already in $DEST_DIR — re-copy?"; then
            info "Keeping existing scripts"
            return
        elif [ "$REINSTALL" -eq 0 ]; then
            info "Scripts already in $DEST_DIR (keeping)"
            return
        fi
    fi
    mkdir -p "$DEST_DIR/cron" "$DEST_DIR/www" /var/log
    touch "$LOGFILE"
    install -m 755 "$SCRIPT_DIR/apcups_collector_mysql.pl"  "$DEST_DIR/cron/"
    install -m 755 "$SCRIPT_DIR/apcups_ui.pl"                "$DEST_DIR/www/index.pl"
    install -m 644 "$SCRIPT_DIR/visual/pt-dark.css"          "$DEST_DIR/www/"
    install -m 644 "$SCRIPT_DIR/visual/bg-bars.js"           "$DEST_DIR/www/"
    info "Scripts installed to $DEST_DIR"
}

# ============================================================
# Apache vhost
# ============================================================
setup_apache() {
    title "Setting up Apache CGI"
    local vhost_file="$APACHE_CONF_D/apcups-monitor.conf"
    local vhost_broken=0
    if [ -f "$vhost_file" ]; then
        # проверяем что путь не пустой и совпадает с DEST_DIR
        if grep -q 'Alias /apcups ""' "$vhost_file" 2>/dev/null || \
           ! grep -q "Alias /apcups " "$vhost_file" 2>/dev/null; then
            vhost_broken=1
            warn "Apache vhost is broken — regenerating"
        elif [ "$REINSTALL" -eq 1 ]; then
            if ! ask "Apache vhost already exists — overwrite?"; then
                info "Keeping existing vhost: $vhost_file"
                return
            fi
        else
            info "Apache vhost already exists: $vhost_file (keeping)"
            return
        fi
    fi

    cat > "$vhost_file" <<-EOVHOST
# APC UPS Monitor — generated $(date)
Alias /apcups $DEST_DIR/www
<Directory $DEST_DIR/www>
    Options +ExecCGI
    AddHandler cgi-script .pl
    DirectoryIndex index.pl
    Require all granted
</Directory>
EOVHOST

    # Debian: enable the conf
    if [ "$PKGMGR" = "apt-get" ]; then
        a2enconf apcups-monitor >/dev/null 2>&1 || true
    fi

    systemctl reload "$APACHE_SVC" 2>/dev/null || systemctl restart "$APACHE_SVC" 2>/dev/null || true
    info "Apache configured — UI at http://$(hostname -I | awk '{print $1}')/apcups/"
}

# ============================================================
# Cron
# ============================================================
setup_cron() {
    title "Setting up cron"
    if [ "$EX_CRON" -eq 1 ]; then
        info "Cron entry already exists: $CRON_FILE (keeping)"
        return
    fi
    # Convert STATTIME to cron interval
    local cron_line=""
    if [ "$A_STATTIME" -le 60 ]; then
        cron_line="* * * * *"
    elif [ "$A_STATTIME" -le 300 ]; then
        cron_line="*/5 * * * *"
    elif [ "$A_STATTIME" -le 600 ]; then
        cron_line="*/10 * * * *"
    elif [ "$A_STATTIME" -le 1800 ]; then
        cron_line="*/30 * * * *"
    else
        cron_line="0 * * * *"
    fi

    cat > "$CRON_FILE" <<-EOCRON
# APC UPS Monitor collector — STATTIME=$A_STATTIME s
$cron_line root $DEST_DIR/cron/apcups_collector_mysql.pl >> $LOGFILE 2>&1
EOCRON
    chmod 644 "$CRON_FILE"
    info "Cron installed: $CRON_FILE  (interval ~$A_STATTIME s)"
}

# ============================================================
# Summary
# ============================================================
print_summary() {
    ok="${GREEN}OK${NC}";  fail="${RED}FAIL${NC}";  skip="${YELLOW}SKIP${NC}"
    echo
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}  APC UPS Monitor — Installation Complete${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo
    echo -e "  ${BOLD}Component              Status   Detail${NC}"
    echo -e "  ${BOLD}──────────────────────────────────────────────${NC}"

    # apcupsd
    if systemctl is-active --quiet apcupsd 2>/dev/null; then
        printf "  %-22s %-8s %s\n" "apcupsd" "$ok" "active"
    else
        printf "  %-22s %-8s %s\n" "apcupsd" "$fail" "not running"
    fi

    # MySQL / MariaDB
    local db_svc=""
    for s in mysql mariadb mysqld; do
        systemctl is-active --quiet "$s" 2>/dev/null && { db_svc="$s"; break; }
    done
    if [ -n "$db_svc" ]; then
        printf "  %-22s %-8s %s\n" "$db_svc" "$ok" "active"
    else
        printf "  %-22s %-8s %s\n" "MySQL/MariaDB" "$fail" "not running"
    fi

    # DB reachable
    local mc="mysql -h $DB_HOST -P $DB_PORT -u $DB_USER"
    [ -n "$DB_PASS" ] && mc="$mc -p$DB_PASS"
    if echo "SELECT 1;" | $mc "$DB_NAME" >/dev/null 2>&1; then
        printf "  %-22s %-8s %s\n" "Database" "$ok" "$DB_NAME@$DB_HOST"
    else
        printf "  %-22s %-8s %s\n" "Database" "$fail" "cannot connect"
    fi

    # Config file
    if [ -f "$CONF_FILE" ]; then
        printf "  %-22s %-8s %s\n" "Config" "$ok" "$CONF_FILE"
    else
        printf "  %-22s %-8s %s\n" "Config" "$fail" "missing"
    fi

    # Collector script
    if [ -f "$DEST_DIR/cron/apcups_collector_mysql.pl" ]; then
        printf "  %-22s %-8s %s\n" "Collector" "$ok" "$DEST_DIR"
    else
        printf "  %-22s %-8s %s\n" "Collector" "$fail" "missing"
    fi

    # Web UI
    if [ -f "$DEST_DIR/www/index.pl" ]; then
        printf "  %-22s %-8s %s\n" "Web UI" "$ok" "$DEST_DIR/www"
    else
        printf "  %-22s %-8s %s\n" "Web UI" "$fail" "missing"
    fi

    # Apache
    if systemctl is-active --quiet "$APACHE_SVC" 2>/dev/null; then
        printf "  %-22s %-8s %s\n" "Apache" "$ok" "$APACHE_SVC active"
    else
        printf "  %-22s %-8s %s\n" "Apache" "$fail" "$APACHE_SVC not running"
    fi

    # Apache vhost
    if [ -f "$APACHE_CONF_D/apcups-monitor.conf" ]; then
        printf "  %-22s %-8s %s\n" "Apache vhost" "$ok" "$APACHE_CONF_D"
    else
        printf "  %-22s %-8s %s\n" "Apache vhost" "$fail" "missing"
    fi

    # Cron
    if [ -f "$CRON_FILE" ]; then
        printf "  %-22s %-8s %s\n" "Cron" "$ok" "$CRON_FILE"
    else
        printf "  %-22s %-8s %s\n" "Cron" "$fail" "missing"
    fi

    # Zabbix template
    if [ -f "$SCRIPT_DIR/apcupsd_zabbix_template_agent.yaml" ]; then
        printf "  %-22s %-8s %s\n" "Zabbix template" "$ok" "import manually"
    else
        printf "  %-22s %-8s %s\n" "Zabbix template" "$skip" "not shipped"
    fi

    # Perl module DBD::mysql
    if perl -e 'use DBD::mysql;' 2>/dev/null; then
        printf "  %-22s %-8s %s\n" "Perl DBD::mysql" "$ok" "loaded"
    else
        printf "  %-22s %-8s %s\n" "Perl DBD::mysql" "$fail" "missing"
    fi

    # apcupsd status file
    if [ -f "$A_STATUSFILE" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$A_STATUSFILE" 2>/dev/null || echo 0) ))
        if [ "$age" -le 120 ]; then
            printf "  %-22s %-8s %s\n" "Status file" "$ok" "${age}s old"
        else
            printf "  %-22s %-8s %s\n" "Status file" "$fail" "${age}s old (stale)"
        fi
    else
        printf "  %-22s %-8s %s\n" "Status file" "$fail" "not found"
    fi

    echo -e "  ${BOLD}──────────────────────────────────────────────${NC}"
    echo
    echo -e "  ${CYAN}URL:${NC}  http://$(hostname -I | awk '{print $1}')/apcups/"
    echo -e "  ${CYAN}Log:${NC}  tail -f $LOGFILE"
    echo
}

# ============================================================
# Uninstall
# ============================================================
do_uninstall() {
    title "APC UPS Monitor — Uninstall"

    # попробуем прочитать конфиг для DEST_DIR, иначе дефолт
    local u_dest="/usr/local/lib/apcups-monitor"
    local u_log="/var/log/apcups-collector.log"
    if [ -f "$CONF_FILE" ]; then
        local u_log=$(awk -F"'" '/apcups_logfile/ {print $2; exit}' "$CONF_FILE" 2>/dev/null || echo "$u_log")
    fi

    echo -e "  ${YELLOW}Will remove:${NC}"
    echo -e "    $CONF_FILE"
    echo -e "    $CRON_FILE"
    echo -e "    $APACHE_CONF_D/apcups-monitor.conf"
    echo -e "    $u_dest"
    echo -e "    $u_log"
    echo -e "    /var/run/apcups-collector.lock"
    echo -e "    /var/run/apcups-shutdown.flag"
    echo

    if ! ask "Proceed with uninstall?"; then
        info "Aborted"
        exit 0
    fi

    # Cron
    if [ -f "$CRON_FILE" ]; then
        rm -f "$CRON_FILE"
        info "Removed: $CRON_FILE"
        systemctl restart crond 2>/dev/null || true
    fi

    # Apache vhost
    if [ -f "$APACHE_CONF_D/apcups-monitor.conf" ]; then
        rm -f "$APACHE_CONF_D/apcups-monitor.conf"
        info "Removed: $APACHE_CONF_D/apcups-monitor.conf"
        if [ "$PKGMGR" = "apt-get" ]; then
            a2disconf apcups-monitor 2>/dev/null || true
        fi
        systemctl reload "$APACHE_SVC" 2>/dev/null || systemctl restart "$APACHE_SVC" 2>/dev/null || true
    fi

    # Config
    [ -f "$CONF_FILE" ] && { rm -f "$CONF_FILE"; info "Removed: $CONF_FILE"; }

    # Scripts
    [ -d "$u_dest" ] && { rm -rf "$u_dest"; info "Removed: $u_dest"; }

    # Log & runtime files
    [ -f "$u_log" ] && { rm -f "$u_log"; info "Removed: $u_log"; }
    [ -f /var/run/apcups-collector.lock ] && { rm -f /var/run/apcups-collector.lock; info "Removed: lock file"; }
    [ -f /var/run/apcups-shutdown.flag ] && { rm -f /var/run/apcups-shutdown.flag; info "Removed: shutdown flag"; }

    # Database (optional)
    echo
    if ask "Drop database '${DB_NAME:-apcups_monitor}'?"; then
        local mc="mysql -h ${DB_HOST:-localhost} -P ${DB_PORT:-3306} -u ${DB_USER:-apcups}"
        [ -n "${DB_PASS:-}" ] && mc="$mc -p$DB_PASS"
        echo "DROP DATABASE IF EXISTS \`${DB_NAME:-apcups_monitor}\`;" | $mc 2>/dev/null && \
            info "Dropped database: ${DB_NAME:-apcups_monitor}" || \
            warn "Could not drop database (connect as root manually)"
    fi

    echo
    echo -e "${GREEN}[*]${NC} Uninstall complete"
}

# ============================================================
# MAIN
# ============================================================
echo -e "${BOLD}${CYAN}APC UPS Monitor Installer v$VERSION${NC}\n"

if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root"
    exit 1
fi

# Uninstall mode
if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
    detect_os
    do_uninstall
    exit 0
fi

detect_os
read_apcupsd_conf

title "Installation plan"
echo "  Scripts from:  $SCRIPT_DIR"
echo "  apcupsd stat:  $A_STATUSFILE  (every ${A_STATTIME}s)"
echo ""
if ! ask "Proceed?"; then
    info "Aborted"
    exit 0
fi

check_deps
verify_apcupsd
setup_mysql
prompt_config
check_existing
generate_config
install_scripts
setup_db
setup_apache
setup_cron
print_summary

