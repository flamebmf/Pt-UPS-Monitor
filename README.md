# Pt UPS Monitor

APC UPS monitoring stack — data collector, web dashboard, and Zabbix integration.

## Components

| File | Description |
|---|---|
| `apcups_collector_mysql.pl` | Collector — reads `apcupsd.status`, stores to MySQL |
| `apcups_ui.pl` | Web dashboard — ApexCharts, PlurumTech dark theme |
| `apcups_ui.sql` | Database schema (`ups_data` + `current_status`) |
| `apcupsd_zabbix_template_agent.yaml` | Zabbix template (import) |
| `zabbix_agent_apcupsd.conf` | Zabbix agent UserParameters |
| `install.sh` | Installer — RHEL & Debian/Ubuntu |

## Quick Start

```bash
sudo bash install.sh
```

Installer handles: dependency detection, apcupsd verification, MySQL setup, Apache vhost, cron.

## License

GNU GPL v3 — [PlurumTech.com](https://plurumtech.com)
