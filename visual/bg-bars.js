/* ============================================================
 * PlurumTech Background Bars — (C) 2024-2025 PlurumTech.com
 * Licensed under GNU GPL v3
 * ============================================================
 * Animated background gradient bars with parallax + fade cycle.
 * Drop into any page — no dependencies.
 *
 * Usage:
 *   <div class="bg-bars" id="bgBars"></div>
 *   <script src="bg-bars.js"></script>
 *
 * Toggle:
 *   <button id="toggleBg" class="pt-bg-btn">BG ON</button>
 *   Click persists to localStorage key "ptBgOff".
 * ============================================================ */

(function(){
  'use strict';

  // ---------- Config ----------
  var NUM   = 35;       // bar count
  var WIN_MUL = 5;      // bar height = viewport * 5
  var MARGIN_MUL = 2;   // vertical margin = viewport * 2
  var DIM_TIME  = 3000; // ms a bar stays dimmed
  var FADE_MIN  = 8;    // min seconds before dim cycle
  var FADE_MAX  = 28;   // max seconds before dim cycle

  // ---------- Init ----------
  var container = document.getElementById("bgBars");
  if (!container) return;

  var winH, winW, barH, marginV;
  var barData = [];
  var startTime = Date.now();

  function recalc() {
    winH = window.innerHeight;
    winW = window.innerWidth;
    barH = winH * WIN_MUL;
    marginV = winH * MARGIN_MUL;
  }
  recalc();

  // Create bars
  for (var i = 0; i < NUM; i++) {
    var bar = document.createElement("div");
    bar.className = "bg-bar";
    if (i % 4 === 0) bar.classList.add("purple");

    var w = 14 + Math.random() * 80;
    var baseLeftPct = (i / NUM) * 100 + (Math.random() - .5) * 6;

    bar.style.width  = w + "px";
    bar.style.height = barH + "px";
    bar.style.top    = "-" + marginV + "px";
    bar.style.left   = baseLeftPct + "%";

    var startDimmed = Math.random() > .55;
    if (startDimmed) bar.classList.add("dim");

    container.appendChild(bar);

    barData.push({
      el: bar,
      width: w,
      speedY: .2 + Math.random() * 2.2,
      speedX: .5 + Math.random() * 1,
      basePosY: (Math.random() - .5) * winH * 1.2,
      baseLeftPct: baseLeftPct,
      nextFade: FADE_MIN + Math.random() * (FADE_MAX - FADE_MIN),
      dimmed: startDimmed,
      dimStart: startDimmed ? startTime - 1e3 - Math.random() * 3000 : 0
    });
  }

  // ---------- Animation loop ----------
  function drift() {
    var now    = Date.now();
    var elapsed = (now - startTime) / 1e3;
    var scrollY = window.pageYOffset;

    barData.forEach(function(d) {
      // Vertical parallax
      var y = d.basePosY - scrollY * d.speedY * .6;
      var wrapRange = barH;
      while (y < -marginV)  y += wrapRange;
      while (y > marginV + barH) y -= wrapRange;

      // Horizontal drift
      var driftPx = (elapsed * d.speedX * winW) / 120;
      driftPx = driftPx % (winW + d.width + 100);
      var barL = (d.baseLeftPct / 100) * winW;
      var xShift = -driftPx;
      var mappedX = ((barL + xShift) % (winW + d.width + 100));
      if (mappedX < -d.width - 50) mappedX += winW + d.width + 100;

      d.el.style.transform =
        "translateY(" + y + "px) translateX(" + (mappedX - barL) + "px)";

      // Fade cycle
      d.nextFade -= .016;
      if (!d.dimmed && d.nextFade <= 0) {
        d.dimmed = true;
        d.dimStart = now;
        d.el.classList.add("dim");
      }
      if (d.dimmed && (now - d.dimStart) > DIM_TIME) {
        d.dimmed = false;
        d.el.classList.remove("dim");
        d.nextFade = FADE_MIN + Math.random() * (FADE_MAX - FADE_MIN);
      }
    });

    requestAnimationFrame(drift);
  }
  drift();

  window.addEventListener("resize", recalc);

  // ---------- Toggle ----------
  window.toggleBgBars = function() {
    var bg  = document.getElementById("bgBars");
    var btn = document.getElementById("toggleBg");
    if (!bg || !btn) return;

    if (bg.classList.contains("off")) {
      bg.classList.remove("off");
      btn.textContent = "BG ON";
      btn.style.opacity = "1";
      localStorage.setItem("ptBgOff", "0");
    } else {
      bg.classList.add("off");
      btn.textContent = "BG OFF";
      btn.style.opacity = ".6";
      localStorage.setItem("ptBgOff", "1");
    }
  };

  // Restore state
  (function() {
    var bg  = document.getElementById("bgBars");
    var btn = document.getElementById("toggleBg");
    if (!bg || !btn) return;

    if (localStorage.getItem("ptBgOff") === "1") {
      bg.classList.add("off");
      btn.textContent = "BG OFF";
      btn.style.opacity = ".6";
    }
  })();
})();
