#!/usr/bin/perl
# ============================================================
# apcups_ui.pl — APC UPS monitoring web UI
# Copyright (C) 2024-2025 PlurumTech.com
# Licensed under GNU GPL v3 — https://www.gnu.org/licenses/gpl-3.0.html
# ============================================================
use strict;
use warnings;
use CGI;
use DBI;
use POSIX qw(strftime);

# Загружаем внешний конфиг если есть
our ($apcups_db_host, $apcups_db_port, $apcups_db_name, $apcups_db_user, $apcups_db_pass, $apcups_stattime);
do '/etc/apcups-monitor.conf' if -f '/etc/apcups-monitor.conf';

# ---------- Настройки ----------
my $db_host      = $apcups_db_host || 'localhost';
my $db_port      = $apcups_db_port || 3306;
my $db_name      = $apcups_db_name || 'apcups_monitor';
my $db_user      = $apcups_db_user || 'apcups';
my $db_pass      = $apcups_db_pass || 'apcups';
my $db_table     = 'ups_data';

my $accent   = '#00d4ff';
my $accent2  = '#7b61ff';
my $dark     = '#04070d';
my $card_bg  = '#0a0f16';
my $text     = '#e4e8ee';
my $muted    = '#7a8294';
my $self     = (split '/', $0)[-1];
# -----------------------------

my @chart_palette = ($accent, $accent2, '#ff6b6b', '#ffd93d', '#6bcb77', '#4d96ff');

my $cgi = CGI->new;
my $timewindow = $cgi->param('timewindow') || '24';
print $cgi->header(-type=>'text/html', -charset=>'utf-8');

# --- MySQL connection ---
my $dsn = "DBI:mysql:host=$db_host;port=$db_port;dbname=$db_name";
my $dbh = DBI->connect($dsn, $db_user, $db_pass, {
    RaiseError => 0, AutoCommit => 1, mysql_enable_utf8 => 1,
}) or die "Cannot connect to MySQL: $DBI::errstr";

# --- Current status from current_status table ---
my $last = $dbh->selectrow_hashref("SELECT model, itemp, timeleft, bcharge
    FROM current_status WHERE id = 1");
my $model   = $last->{model}   // 'N/A';
my $temp    = $last->{itemp}   // 'N/A';
my $remain  = $last->{timeleft} // 'N/A';
my $charge_cur = $last->{bcharge} // 0;

# Fallback: если current_status пуст — берём из последней записи ups_data
unless ($charge_cur && $charge_cur > 0) {
    my $fb = $dbh->selectrow_hashref(
        "SELECT bcharge FROM $db_table ORDER BY recorded_at DESC LIMIT 1");
    $charge_cur = $fb->{bcharge} // 0;
}
$model  =~ s/\s+$//;
$temp   =~ s/\s+\S+$//;
$remain =~ s/\s+\S+$//;

# --- Time-filtered data ---
my (@volts_real, @charge_real, @load_real);
my ($maxvolts, $minvolts) = (0, 300);
my ($maxc, $minc, $maxl, $minl) = (0, 100, 0, 100);

my $rows = $dbh->selectall_arrayref(
    "SELECT UNIX_TIMESTAMP(recorded_at) * 1000 AS js_ts, linev, bcharge, loadpct
     FROM $db_table
     WHERE recorded_at >= NOW() - INTERVAL ? HOUR
     ORDER BY recorded_at ASC",
    { Slice => {} }, $timewindow
);

my $total = scalar @$rows;
my $n_buckets = 200;

if ($total <= $n_buckets) {
    # Мало данных — строгая дедупликация
    my ($v_old, $c_old, $l_old) = (0, 0, 0);
    my ($first_ts, $first_v, $first_c, $first_l);
    foreach my $r (@$rows) {
        my $ts = $r->{js_ts};
        my ($v, $c, $l) = ($r->{linev}+0, $r->{bcharge}+0, $r->{loadpct}+0);
        if (!defined $first_ts) { ($first_ts, $first_v, $first_c, $first_l) = ($ts, $v, $c, $l) }
        if ($v > $maxvolts) { $maxvolts = $v }
        if ($v < $minvolts) { $minvolts = $v }
        if ($c > $maxc) { $maxc = $c }
        if ($c < $minc) { $minc = $c }
        if ($l > $maxl) { $maxl = $l }
        if ($l < $minl) { $minl = $l }
        if ($v != $v_old) { push @volts_real,  "{\"x\":$ts,\"y\":$v}"; $v_old = $v }
        if ($c != $c_old) { push @charge_real, "{\"x\":$ts,\"y\":$c}"; $c_old = $c }
        if ($l != $l_old) { push @load_real,   "{\"x\":$ts,\"y\":$l}"; $l_old = $l }
    }
    # Гарантируем минимум 10 точек заряд / 2 нагрузки (линия не видна из 0-1)
    if (@charge_real < 10 && defined $first_ts) {
        @charge_real = ("{\"x\":$first_ts,\"y\":$first_c}");
        my $step = int($total / 10) || 1;
        for (my $i = $step; $i < $total; $i += $step) {
            my $r = $rows->[$i];
            push @charge_real, "{\"x\":$r->{js_ts},\"y\":".($r->{bcharge}+0)."}";
        }
    }
    if (@load_real < 2 && defined $first_ts) {
        @load_real = ("{\"x\":$first_ts,\"y\":$first_l}");
        push @load_real, "{\"x\":$rows->[-1]{js_ts},\"y\":".($rows->[-1]{loadpct}+0)."}";
    }
} else {
    # Много данных — агрегация по корзинам, общая ось времени
    my $bsize = int($total / $n_buckets);
    for (my $bi = 0; $bi < $total; $bi += $bsize) {
        my $be = ($bi + $bsize < $total) ? $bi + $bsize - 1 : $total - 1;
        my $r_first = $rows->[$bi];
        my $r_last  = $rows->[$be];
        my $ts = $r_last->{js_ts};

        my ($vmin, $vmax) = ($r_first->{linev}+0, $r_first->{linev}+0);
        my ($cmin, $cmax) = ($r_first->{bcharge}+0, $r_first->{bcharge}+0);
        my ($lmin, $lmax) = ($r_first->{loadpct}+0, $r_first->{loadpct}+0);
        for (my $j = $bi; $j <= $be; $j++) {
            my $v = $rows->[$j]{linev} + 0;
            my $c = $rows->[$j]{bcharge} + 0;
            my $l = $rows->[$j]{loadpct} + 0;
            if ($v < $vmin) { $vmin = $v }
            if ($v > $vmax) { $vmax = $v }
            if ($v > $maxvolts) { $maxvolts = $v }
            if ($v < $minvolts) { $minvolts = $v }
            if ($c < $cmin) { $cmin = $c; $minc = $c if $c < $minc }
            if ($c > $cmax) { $cmax = $c; $maxc = $c if $c > $maxc }
            if ($l < $lmin) { $lmin = $l; $minl = $l if $l < $minl }
            if ($l > $lmax) { $lmax = $l; $maxl = $l if $l > $maxl }
        }
        push @volts_real,  "{\"x\":$ts,\"y\":$vmin}";
        push @volts_real,  "{\"x\":$ts,\"y\":$vmax}";
        push @charge_real, "{\"x\":$ts,\"y\":$cmin}";
        push @charge_real, "{\"x\":$ts,\"y\":$cmax}";
        push @load_real,   "{\"x\":$ts,\"y\":$lmin}";
        push @load_real,   "{\"x\":$ts,\"y\":$lmax}";
    }
}
$dbh->disconnect;

# --- HTML ---
print '<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="theme-color" content="'.$dark.'">
<title>UPS Monitor &mdash; PlurumTech</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@400;500;700;900&display=swap" rel="stylesheet">
<link rel="stylesheet" href="pt-dark.css">
<script src="https://cdn.jsdelivr.net/npm/apexcharts"></script>
</head>
<body>
<div class="bg-bars" id="bgBars"></div>
<div class="navbar"><div class="nav-inner">
 <a class="nav-brand" href="#">PlurumTech UPS</a>
 <ul class="nav-links">
  <li><a href="'.$self.'?timewindow='.$timewindow.'">Refresh</a></li>
  <li><a href="https://plurumtech.ru">plurumtech.ru</a></li>
   <li><a href="#" id="toggleBg" onclick="toggleBgBars();return false" class="pt-bg-btn">BG ON</a></li>
 </ul>
</div></div>

<div class="container">
 <div class="header-block">
  <h1>UPS <span class="grad-text">'.$model.'</span></h1>
  <div class="header-stats">
   <div class="stat-badge">Temp <span class="stat-val">'.$temp.' C</span></div>
   <div class="stat-badge">Time Left <span class="stat-val">'.$remain.' min</span></div>
  </div>
 </div>

 <div class="battery-bar">
  <span class="battery-bar-label">Battery</span>
  <div class="battery-bar-track"><div class="battery-bar-fill" id="batteryFill" style="width:'.$charge_cur.'%"></div></div>
  <span class="battery-bar-val grad-text">'.$charge_cur.'%</span>
 </div>

 <div class="time-select">
  <a class="time-btn" href="'.$self.'?timewindow=1">1h</a>
  <a class="time-btn" href="'.$self.'?timewindow=2">2h</a>
  <a class="time-btn" href="'.$self.'?timewindow=6">6h</a>
  <a class="time-btn" href="'.$self.'?timewindow=12">12h</a>
  <a class="time-btn" href="'.$self.'?timewindow=24">24h</a>
  <a class="time-btn" href="'.$self.'?timewindow=48">48h</a>
  <a class="time-btn" href="'.$self.'?timewindow=72">72h</a>
  <a class="time-btn" href="'.$self.'?timewindow=720">30d</a>
 </div>

 <div class="chart-grid">
  <div class="chart-card full" id="volts"></div>
  <div class="chart-row">
   <div class="chart-card half" id="charge"></div>
   <div class="chart-card half" id="load"></div>
  </div>
 </div>
</div>

<footer>PlurumTech UPS Monitor &copy; '. (strftime "%Y", localtime) .'</footer>

<script>
var ptDark = {
  chart: { toolbar:{show:false}, zoom:{enabled:true}, background:"transparent",
    foreColor:"'.$muted.'", fontFamily:"Roboto" },
  xaxis: { type:"datetime", labels:{style:{colors:"'.$muted.'"}},
    axisBorder:{color:"rgba(255,255,255,.06)"}, axisTicks:{color:"rgba(255,255,255,.06)"} },
  yaxis: { labels:{style:{colors:"'.$muted.'"}} },
  grid: { borderColor:"rgba(255,255,255,.04)",
    row:{colors:["rgba(255,255,255,.02)","transparent"]} },
  tooltip: { theme:"dark", x:{format:"dd MMM HH:mm"} },
};
var vcolor = [function(o){return "'.$accent.'"}];
var ccolor = [function(o){return "'.$accent2.'"}];
var lcolor = [function(o){return "#ff6b6b"}];

var opts_v = {
  chart: { ...ptDark.chart, height:280, type:"line" },
  stroke: { curve:"stepline", width:2 },
  colors: vcolor,
  xaxis: ptDark.xaxis,
  yaxis: { ...ptDark.yaxis, decimalsInFloat:1 },
  grid: ptDark.grid,
  tooltip: ptDark.tooltip,
  title: { text:"Input Voltage (V)", align:"left", style:{color:"'.$text.'",fontWeight:700,fontSize:"14px"} },
  series: [{ name:"Volts", data:[' . join(', ', @volts_real) . '] }],
  annotations: {
   yaxis:[
    { y:'.$maxvolts.', borderColor:"'.$accent.'", borderWidth:1, strokeDashArray:4, opacity:.7,
      label:{ borderColor:"'.$accent.'", style:{color:"'.$dark.'",background:"'.$accent.'"}, text:"Max: '.$maxvolts.' V" } },
    { y:'.$minvolts.', borderColor:"'.$accent2.'", borderWidth:1, strokeDashArray:4, opacity:.7,
      label:{ borderColor:"'.$accent2.'", style:{color:"'.$dark.'",background:"'.$accent2.'"}, text:"Min: '.$minvolts.' V" } }
   ] },
};

var opts_c = {
  chart: { ...ptDark.chart, height:250, type:"line" },
  stroke: { curve:"smooth", width:2 },
  colors: ccolor,
  xaxis: ptDark.xaxis,
  yaxis: { ...ptDark.yaxis, decimalsInFloat:1 },
  grid: ptDark.grid,
  tooltip: ptDark.tooltip,
  title: { text:"Charge (%)", align:"left", style:{color:"'.$text.'",fontWeight:700,fontSize:"14px"} },
  series: [{ name:"Charge", data:[' . join(', ', @charge_real) . '] }],
  annotations: {
   yaxis:[
    { y:'.$maxc.', borderColor:"'.$accent2.'", borderWidth:1, strokeDashArray:4, opacity:.7,
      label:{ borderColor:"'.$accent2.'", style:{color:"'.$dark.'",background:"'.$accent2.'"}, text:"Max: '.$maxc.'%" } },
    { y:'.$minc.', borderColor:"'.$accent2.'", borderWidth:1, strokeDashArray:4, opacity:.7,
      label:{ borderColor:"'.$accent2.'", style:{color:"'.$dark.'",background:"'.$accent2.'"}, text:"Min: '.$minc.'%" } }
   ] },
};

var opts_l = {
  chart: { ...ptDark.chart, height:250, type:"line" },
  stroke: { curve:"smooth", width:2 },
  colors: lcolor,
  xaxis: ptDark.xaxis,
  yaxis: { ...ptDark.yaxis, decimalsInFloat:1 },
  grid: ptDark.grid,
  tooltip: ptDark.tooltip,
  title: { text:"Load (%)", align:"left", style:{color:"'.$text.'",fontWeight:700,fontSize:"14px"} },
  series: [{ name:"Load", data:[' . join(', ', @load_real) . '] }],
  annotations: {
   yaxis:[
    { y:'.$maxl.', borderColor:"#ff6b6b", borderWidth:1, strokeDashArray:4, opacity:.7,
      label:{ borderColor:"#ff6b6b", style:{color:"'.$dark.'",background:"#ff6b6b"}, text:"Max: '.$maxl.'%" } },
    { y:'.$minl.', borderColor:"#ff6b6b", borderWidth:1, strokeDashArray:4, opacity:.7,
      label:{ borderColor:"#ff6b6b", style:{color:"'.$dark.'",background:"#ff6b6b"}, text:"Min: '.$minl.'%" } }
   ] },
};

new ApexCharts(document.querySelector("#volts"), opts_v).render();
new ApexCharts(document.querySelector("#charge"), opts_c).render();
new ApexCharts(document.querySelector("#load"), opts_l).render();

var tw='.$timewindow.';
document.querySelectorAll(".time-btn").forEach(function(b){
  if(b.href.endsWith("timewindow="+tw)) b.classList.add("active");
});

var b = document.getElementById("batteryFill");
b.style.transition = "none";
b.style.width = "0%";
setTimeout(function(){ b.style.transition = "width .8s ease"; b.style.width="'.$charge_cur.'%" }, 100);
</script>
<script src="bg-bars.js"></script>
</body>
</html>';
