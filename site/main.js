/* Slimg landing — tiny progressive enhancement. Page is fully usable without JS. */
(function () {
  "use strict";

  // Current year in footer
  var yearEl = document.getElementById("year");
  if (yearEl) yearEl.textContent = String(new Date().getFullYear());

  // Animate the hero before→after size bars on first view.
  // CSS already sets the final width via `width: var(--to)`, so if JS or
  // IntersectionObserver is unavailable the bars simply show filled.
  var reduceMotion =
    window.matchMedia &&
    window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  var bars = document.querySelectorAll(".js-bar");
  if (!bars.length || reduceMotion || !("IntersectionObserver" in window)) return;

  // Start collapsed, then ease to the target width once on screen.
  bars.forEach(function (bar) {
    bar.style.transition = "none";
    bar.style.width = "0%";
  });

  var io = new IntersectionObserver(
    function (entries, obs) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        var bar = entry.target;
        // next frame so the 0% is committed before transitioning
        requestAnimationFrame(function () {
          bar.style.transition = "width .9s cubic-bezier(.22,.61,.36,1)";
          bar.style.width = "var(--to)";
        });
        obs.unobserve(bar);
      });
    },
    { threshold: 0.4 }
  );

  bars.forEach(function (bar) {
    io.observe(bar);
  });
})();
