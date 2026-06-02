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
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${GREEN}[*]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[X]${NC} $*"; }
title() { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }
ask()   { echo -en "${CYAN}[?]${NC} $1 [Y/n] "; read -r r; [[ "$r" =~ ^[Nn] ]] && return 1 || return 0; }
get()   { echo -en "${CYAN}[?]${NC} $1: "; read -r r; echo "$r"; }

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

    command -v mysql    >/dev/null 2>&1 || { warn "mysql client missing"; apt_or_dnf_install mysql-client mysql; }
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
                dnf install -y mariadb-server
                systemctl enable --now mariadb
            else
                apt-get install -y mariadb-server
            fi
            info "MariaDB installed. Run mysql_secure_installation if needed."
        fi
    fi

    DB_HOST=$(get "MySQL host"               || echo "localhost")
    DB_PORT=$(get "MySQL port [3306]"        || echo "3306")
    DB_NAME=$(get "Database name [apcups_monitor]" || echo "apcups_monitor")
    DB_USER=$(get "DB user [apcups]"          || echo "apcups")
    DB_PASS=$(get "DB password [apcups]"       || echo "apcups")
    MYSQL_ROOT_USER=$(get "MySQL admin user [root]" || echo "root")
    MYSQL_ROOT_PASS=$(get "MySQL admin password (empty if none)" || echo "")

    local mysql_cmd="mysql -h $DB_HOST -P $DB_PORT -u $MYSQL_ROOT_USER"
    [ -n "$MYSQL_ROOT_PASS" ] && mysql_cmd="$mysql_cmd -p$MYSQL_ROOT_PASS"

    info "Creating database and user..."
    $mysql_cmd <<-EOSQL 2>/dev/null || {
        err "Cannot connect to MySQL at $DB_HOST:$DB_PORT as $MYSQL_ROOT_USER"
        err "Check credentials, firewall, and bind-address in my.cnf"
        exit 1
    }
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'%';
FLUSH PRIVILEGES;
EOSQL

    info "Creating tables..."
    $mysql_cmd "$DB_NAME" < "$SCRIPT_DIR/apcups_ui.sql"
    info "Database ready: $DB_NAME@$DB_HOST:$DB_PORT (user: $DB_USER)"
}

# ============================================================
# Generate config file
# ============================================================
generate_config() {
    title "Generating $CONF_FILE"
    DEST_DIR=$(get "Install scripts to [/usr/local/lib/apcups-monitor]" || echo "/usr/local/lib/apcups-monitor")
    SHUTDOWN_THRESHOLD=$(get "Shutdown battery threshold % [15]" || echo "15")
    LOGFILE="/var/log/apcups-collector.log"

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
    mkdir -p "$DEST_DIR" /var/log
    touch "$LOGFILE"

    install -m 755 "$SCRIPT_DIR/apcups_collector_mysql.pl"  "$DEST_DIR/"
    install -m 755 "$SCRIPT_DIR/apcups_ui.pl"               "$DEST_DIR/"

    info "Scripts installed to $DEST_DIR"
}

# ============================================================
# Apache vhost
# ============================================================
setup_apache() {
    title "Setting up Apache CGI"
    local ui_path="$DEST_DIR/apcups_ui.pl"
    local vhost_file="$APACHE_CONF_D/apcups-monitor.conf"

    cat > "$vhost_file" <<-EOVHOST
# APC UPS Monitor — generated $(date)
Alias /apcups "$DEST_DIR"
<Directory "$DEST_DIR">
    Options +ExecCGI
    AddHandler cgi-script .pl
    Require all granted
</Directory>
EOVHOST

    # Debian: enable the conf
    if [ "$PKGMGR" = "apt-get" ]; then
        a2enconf apcups-monitor >/dev/null 2>&1 || true
    fi

    systemctl reload "$APACHE_SVC" 2>/dev/null || systemctl restart "$APACHE_SVC" 2>/dev/null || true
    info "Apache configured — UI at http://$(hostname -I | awk '{print $1}')/apcups/apcups_ui.pl"
}

# ============================================================
# Cron
# ============================================================
setup_cron() {
    title "Setting up cron"
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
$cron_line root $DEST_DIR/apcups_collector_mysql.pl >> $LOGFILE 2>&1
EOCRON
    chmod 644 "$CRON_FILE"
    info "Cron installed: $CRON_FILE  (interval ~$A_STATTIME s)"
}

# ============================================================
# Summary
# ============================================================
print_summary() {
    echo
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo -e "${BOLD}${CYAN}  APC UPS Monitor — Installation Complete${NC}"
    echo -e "${BOLD}${CYAN}============================================${NC}"
    echo
    echo -e "  Config:     ${GREEN}$CONF_FILE${NC}"
    echo -e "  Scripts:    ${GREEN}$DEST_DIR${NC}"
    echo -e "  DB:         ${GREEN}$DB_NAME@$DB_HOST:$DB_PORT${NC}"
    echo -e "  UI:         ${GREEN}http://$(hostname -I | awk '{print $1}')/apcups/apcups_ui.pl${NC}"
    echo -e "  Log:        ${GREEN}$LOGFILE${NC}"
    echo -e "  Cron:       ${GREEN}$CRON_FILE${NC}"
    echo -e "  Status:     ${GREEN}$A_STATUSFILE${NC}"
    echo
    echo -e "  ${CYAN}Verify:${NC}"
    echo -e "    tail -f $LOGFILE"
    echo -e "    $DEST_DIR/apcups_collector_mysql.pl  (dry-run)"
    echo
}

# ============================================================
# MAIN
# ============================================================
echo -e "${BOLD}${CYAN}APC UPS Monitor Installer v$VERSION${NC}\n"

if [ "$(id -u)" -ne 0 ]; then
    err "This script must be run as root"
    exit 1
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
generate_config
install_scripts
setup_apache
setup_cron
print_summary

