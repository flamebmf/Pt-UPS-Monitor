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
<script src="https://cdn.jsdelivr.net/npm/apexcharts"></script>
<style>
:root {
  --bg: '.$dark.'; --card: '.$card_bg.'; --accent: '.$accent.';
  --accent2: '.$accent2.'; --text: '.$text.'; --muted: '.$muted.';
}
* { margin:0; padding:0; box-sizing:border-box }
body {
  font-family: "Roboto",sans-serif; background:var(--bg); color:var(--text);
  min-height:100vh; overflow-x:hidden;
}
body::before {
  content:""; position:fixed; inset:0;
  background:radial-gradient(ellipse at 20% 20%, rgba(0,212,255,0.03) 0%, transparent 60%),
             radial-gradient(ellipse at 80% 60%, rgba(123,97,255,0.03) 0%, transparent 60%);
  pointer-events:none; z-index:0;
}
.glass {
  background:rgba(10,15,22,.9); border:1px solid rgba(255,255,255,.06);
  backdrop-filter:blur(10px); border-radius:16px; position:relative; z-index:1;
}
.navbar {
  position:fixed; top:0; left:0; right:0; z-index:100;
  background:rgba(4,7,13,.85); backdrop-filter:blur(20px);
  border-bottom:1px solid rgba(255,255,255,.04); padding:12px 0;
}
.nav-inner {
  max-width:1320px; margin:0 auto; padding:0 24px;
  display:flex; align-items:center; justify-content:space-between;
}
.nav-brand {
  font-size:1.2rem; font-weight:900; letter-spacing:-0.5px;
  background:linear-gradient(135deg, var(--accent), var(--accent2));
  -webkit-background-clip:text; -webkit-text-fill-color:transparent;
  text-decoration:none;
}
.nav-links { display:flex; gap:24px; list-style:none }
.nav-links a {
  color:var(--muted); text-decoration:none; font-size:.78rem;
  font-weight:700; text-transform:uppercase; letter-spacing:1px; transition:color .2s;
}
.nav-links a:hover { color:var(--accent) }
.container { max-width:1320px; margin:0 auto; padding:80px 24px 20px; position:relative; z-index:1 }
.header-block { text-align:center; margin-bottom:16px }
.header-block h1 { font-size:1.6rem; font-weight:900; letter-spacing:-1px; margin-bottom:6px }
.grad-text { background:linear-gradient(135deg,var(--accent),var(--accent2)); -webkit-background-clip:text; -webkit-text-fill-color:transparent }
.header-stats { display:flex; justify-content:center; gap:32px; margin-top:12px; flex-wrap:wrap }
.stat-badge {
  background:rgba(255,255,255,.04); border:1px solid rgba(255,255,255,.08);
  border-radius:8px; padding:6px 12px; font-size:.78rem;
}
.stat-val { font-weight:700; color:var(--accent) }
.chart-grid { display:flex; flex-direction:column; gap:14px }
.chart-row { display:flex; gap:14px }
.chart-card {
  background:rgba(10,15,22,.9); border:1px solid rgba(255,255,255,.06);
  backdrop-filter:blur(10px); border-radius:16px; padding:14px; min-height:0;
}
.chart-card.full { width:100% }
.chart-card.half  { flex:1; min-width:0 }
.battery-bar {
  display:flex; align-items:center; gap:16px; padding:12px 20px;
  background:rgba(10,15,22,.9); border:1px solid rgba(255,255,255,.06);
  backdrop-filter:blur(10px); border-radius:12px;
}
.battery-bar-label { font-size:.78rem; font-weight:700; text-transform:uppercase; letter-spacing:2px; color:var(--muted); white-space:nowrap }
.battery-bar-track {
  flex:1; height:18px; background:rgba(255,255,255,.06); border-radius:9px; overflow:hidden;
}
.battery-bar-fill {
  height:100%; border-radius:9px; transition:width .5s ease;
  background:linear-gradient(90deg,'.$accent.','.$accent2.');
}
.battery-bar-val { font-size:1.1rem; font-weight:900; min-width:48px; text-align:right }
.time-select {
  display:flex; justify-content:center; gap:6px; flex-wrap:wrap; margin-bottom:16px;
}
.time-btn {
  background:rgba(255,255,255,.04); color:var(--muted); border:1px solid rgba(255,255,255,.08);
  padding:6px 14px; border-radius:8px; font-size:.75rem; font-weight:700;
  text-decoration:none; text-transform:uppercase; letter-spacing:.5px; transition:all .2s;
}
.time-btn:hover, .time-btn.active { color:var(--accent); border-color:var(--accent); background:rgba(0,212,255,.08) }
footer { text-align:center; padding:12px; font-size:.72rem; color:var(--muted); position:relative; z-index:1 }
.bg-bars { position:fixed; inset:0; z-index:0; pointer-events:none; overflow:hidden }
.bg-bar {
  position:absolute; border-radius:999px; will-change:transform,opacity; opacity:1;
  transition:opacity 3s ease;
  background:linear-gradient(180deg,
    transparent 0%, transparent 10%,
    rgba(0,212,255,.06) 25%, rgba(0,212,255,.25) 50%, rgba(0,212,255,.06) 75%,
    transparent 90%, transparent 100%);
  box-shadow:0 0 12px rgba(0,212,255,.12);
}
.bg-bar.dim { opacity:.12 }
.bg-bar.purple {
  background:linear-gradient(180deg,
    transparent 0%, transparent 10%,
    rgba(123,97,255,.05) 25%, rgba(123,97,255,.2) 50%, rgba(123,97,255,.05) 75%,
    transparent 90%, transparent 100%);
  box-shadow:0 0 12px rgba(123,97,255,.12);
}
#bgBars.off { display:none }
</style>
</head>
<body>
<div class="bg-bars" id="bgBars"></div>
<div class="navbar"><div class="nav-inner">
 <a class="nav-brand" href="#">PlurumTech UPS</a>
 <ul class="nav-links">
  <li><a href="'.$self.'?timewindow='.$timewindow.'">Refresh</a></li>
  <li><a href="https://plurumtech.ru">plurumtech.ru</a></li>
  <li><a href="#" id="toggleBg" onclick="toggleBgBars();return false" style="font-size:.7rem;border:1px solid rgba(255,255,255,.12);border-radius:6px;padding:3px 10px">BG ON</a></li>
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

// Подсветка активной кнопки
var tw='.$timewindow.';
document.querySelectorAll(".time-btn").forEach(function(b){
  if(b.href.endsWith("timewindow="+tw)) b.classList.add("active");
});

// Анимация батареи
var b = document.getElementById("batteryFill");
b.style.transition = "none";
b.style.width = "0%";
setTimeout(function(){ b.style.transition = "width .8s ease"; b.style.width="'.$charge_cur.'%" }, 100);

// Background bars — PlurumTech original
(function(){
  var c=document.getElementById("bgBars"); if(!c)return;
  var NUM=35, winH, winW, barH, marginV, startTime=Date.now(), barData=[];
  function recalc(){ winH=window.innerHeight; winW=window.innerWidth; barH=winH*5; marginV=winH*2 }
  recalc();
  for(var i=0;i<NUM;i++){
    var bar=document.createElement("div"); bar.className="bg-bar";
    if(i%4===0) bar.classList.add("purple");
    var w=14+Math.random()*80;
    var baseLeftPct=(i/NUM)*100+(Math.random()-.5)*6;
    bar.style.width=w+"px"; bar.style.height=barH+"px";
    bar.style.top="-"+marginV+"px"; bar.style.left=baseLeftPct+"%";
    var startDimmed=Math.random()>.55;
    if(startDimmed) bar.classList.add("dim");
    c.appendChild(bar);
    barData.push({el:bar,width:w,speedY:.2+Math.random()*2.2,speedX:.5+Math.random()*1,
      basePosY:(Math.random()-.5)*winH*1.2,baseLeftPct:baseLeftPct,nextFade:8+Math.random()*12,
      dimmed:startDimmed,dimStart:startDimmed?startTime-1e3-Math.random()*3e3:0});
  }
  function drift(){
    var now=Date.now(), elapsed=(now-startTime)/1e3, scrollY=window.pageYOffset;
    barData.forEach(function(d){
      var y=d.basePosY-scrollY*d.speedY*.6, wrapRange=barH;
      while(y<-marginV) y+=wrapRange; while(y>marginV+barH) y-=wrapRange;
      var driftPx=(elapsed*d.speedX*winW)/120;
      driftPx=driftPx%(winW+d.width+100);
      var barL=(d.baseLeftPct/100)*winW, xShift=-driftPx;
      var mappedX=((barL+xShift)%(winW+d.width+100));
      if(mappedX<-d.width-50) mappedX+=winW+d.width+100;
      d.el.style.transform="translateY("+y+"px) translateX("+(mappedX-barL)+"px)";
      d.nextFade-=.016;
      if(!d.dimmed&&d.nextFade<=0){ d.dimmed=true; d.dimStart=now; d.el.classList.add("dim") }
      if(d.dimmed&&(now-d.dimStart)>3e3){ d.dimmed=false; d.el.classList.remove("dim"); d.nextFade=8+Math.random()*20 }
    });
    requestAnimationFrame(drift);
  }
  drift();
  window.addEventListener("resize",recalc);
})();

(function initBg(){
  var bg=document.getElementById("bgBars"), btn=document.getElementById("toggleBg");
  if(localStorage.getItem("ptBgOff")==="1"){
    bg.classList.add("off"); btn.textContent="BG OFF"; btn.style.opacity=".6";
  }
})();
function toggleBgBars(){
  var bg=document.getElementById("bgBars"), btn=document.getElementById("toggleBg");
  if(bg.classList.contains("off")){
    bg.classList.remove("off"); btn.textContent="BG ON"; btn.style.opacity="1";
    localStorage.setItem("ptBgOff","0");
  }else{
    bg.classList.add("off"); btn.textContent="BG OFF"; btn.style.opacity=".6";
    localStorage.setItem("ptBgOff","1");
  }
}
</script>
</body>
</html>';
