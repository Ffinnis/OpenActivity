// OpenActivity landing page: nav state, scroll reveals, counters, the tour, and two small loops.

(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------- Nav ----------
  const nav = document.querySelector(".nav");
  const onScroll = () => nav.classList.toggle("scrolled", window.scrollY > 24);
  onScroll();
  window.addEventListener("scroll", onScroll, { passive: true });

  // ---------- Reveal on scroll ----------
  const reveals = document.querySelectorAll(".reveal");
  if (reduceMotion || !("IntersectionObserver" in window)) {
    reveals.forEach((el) => el.classList.add("in"));
  } else {
    const io = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        const el = entry.target;
        // Stagger siblings that enter together.
        const siblings = [...el.parentElement.children].filter((c) => c.classList.contains("reveal"));
        el.style.transitionDelay = `${(siblings.indexOf(el) % 4) * 80}ms`;
        el.classList.add("in");
        io.unobserve(el);
      });
    }, { rootMargin: "0px 0px -10% 0px", threshold: 0.12 });
    reveals.forEach((el) => io.observe(el));
  }

  // ---------- Counters ----------
  const counters = document.querySelectorAll("[data-count]");
  const runCounter = (el) => {
    const target = Number(el.dataset.count);
    if (reduceMotion || target === 0) { el.textContent = String(target); return; }
    const start = performance.now();
    const duration = 1400;
    const tick = (now) => {
      const t = Math.min(1, (now - start) / duration);
      const eased = 1 - Math.pow(1 - t, 3);
      el.textContent = String(Math.round(target * eased));
      if (t < 1) requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  };
  if ("IntersectionObserver" in window) {
    const cio = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        runCounter(entry.target);
        cio.unobserve(entry.target);
      });
    }, { threshold: 0.5 });
    counters.forEach((el) => cio.observe(el));
  } else {
    counters.forEach(runCounter);
  }

  // ---------- Hero: the fold fragment folds and unfolds ----------
  const fold = document.querySelector(".float-fold");
  const foldCount = document.getElementById("fold-count");
  if (fold && !reduceMotion) {
    let folded = false;
    setInterval(() => {
      folded = !folded;
      fold.classList.toggle("folded", folded);
      foldCount.textContent = folded ? "1 row" : "14 processes";
    }, 3200);
  }

  // ---------- Bento: the app row opens and closes ----------
  const rowDemo = document.getElementById("row-demo");
  if (rowDemo && !reduceMotion) {
    setTimeout(() => rowDemo.classList.add("open"), 1200);
    setInterval(() => rowDemo.classList.toggle("open"), 4200);
  } else if (rowDemo) {
    rowDemo.classList.add("open");
  }

  // ---------- Tour ----------
  const shots = {
    cpu: { src: "assets/cpu-light.webp", alt: "The CPU page: load now and today, a bar for every core, a live chart and apps sorted by CPU with their process counts.", caption: "Load split into user and system, every core, today’s average and peak, and the apps behind it." },
    memory: { src: "assets/memory-light.webp", alt: "The Memory page: memory in use, a breakdown by type, swap, a memory graph and apps sorted by memory.", caption: "The split macOS itself uses, plus pressure, swap, and each app’s real footprint." },
    projects: { src: "assets/projects-light.webp", alt: "The Projects page: an idle-servers banner and four projects with node and python servers, their ports and Stop buttons.", caption: "Dev servers grouped by project with their ports. Idle ones are pointed out; stopping them asks first." },
    sensors: { src: "assets/sensors-light.webp", alt: "The Sensors page: CPU and GPU temperatures, fan speeds, a temperature chart and accessory batteries.", caption: "CPU and GPU temperatures, fan speeds, and the battery of your AirPods, mouse, keyboard and trackpad." },
    settings: { src: "assets/settings-light.webp", alt: "The Settings window: menu bar options, alert thresholds, history retention and launch at login.", caption: "Menu bar style, alert thresholds, history retention and launch at login. Everything is optional." },
  };
  const tabs = document.querySelectorAll(".tour-tabs button");
  const tourImg = document.getElementById("tour-img");
  const tourCaption = document.getElementById("tour-caption");
  tabs.forEach((tab) => {
    tab.addEventListener("click", () => {
      const shot = shots[tab.dataset.shot];
      tabs.forEach((other) => other.setAttribute("aria-selected", String(other === tab)));
      tourCaption.textContent = shot.caption;
      if (reduceMotion) { tourImg.src = shot.src; tourImg.alt = shot.alt; return; }
      tourImg.classList.add("swapping");
      const next = new Image();
      next.src = shot.src;
      const swap = () => { tourImg.src = shot.src; tourImg.alt = shot.alt; requestAnimationFrame(() => tourImg.classList.remove("swapping")); };
      next.decode ? next.decode().then(swap, swap) : (next.onload = swap);
    });
  });
  window.addEventListener("load", () => {
    Object.values(shots).forEach((shot) => { const img = new Image(); img.src = shot.src; });
  });

  // ---------- Hero mockup: a gentle tilt that follows the cursor ----------
  const mockup = document.getElementById("mockup");
  const visual = document.querySelector(".hero-visual");
  if (mockup && visual && !reduceMotion && window.matchMedia("(hover: hover)").matches) {
    let raf = 0;
    visual.addEventListener("mousemove", (event) => {
      const r = visual.getBoundingClientRect();
      const x = (event.clientX - r.left) / r.width - 0.5;
      const y = (event.clientY - r.top) / r.height - 0.5;
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(() => {
        mockup.style.transition = "transform 0.4s cubic-bezier(0.22,1,0.36,1)";
        mockup.style.transform = `rotateY(${x * 4}deg) rotateX(${-y * 4}deg)`;
      });
    });
    visual.addEventListener("mouseleave", () => {
      mockup.style.transition = "transform 0.8s cubic-bezier(0.22,1,0.36,1)";
      mockup.style.transform = "";
    });
  }
})();
