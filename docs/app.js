// OpenActivity landing page: the hero fold, the tour, and the copy button.

(() => {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  // ---------- The fold ----------
  // An illustrative slice of a busy Mac: first as Activity Monitor lists it, then filed by app.

  const processes = [
    ["Safari Web Content", "612 MB"],
    ["SourceKitService", "1.1 GB"],
    ["Slack Helper (Renderer)", "486 MB"],
    ["com.docker.backend", "1.4 GB"],
    ["node", "391 MB"],
    ["Safari Web Content", "388 MB"],
    ["Xcode", "1.6 GB"],
    ["mds_stores", "214 MB"],
    ["Slack Helper (GPU)", "198 MB"],
    ["zsh", "12 MB"],
    ["Music", "243 MB"],
    ["com.apple.WebKit.Networking", "94 MB"],
  ];

  const apps = [
    ["Xcode", 11, "3.1 GB", "#30B0C7"],
    ["Safari", 14, "2.4 GB", "#1575F9"],
    ["Docker", 9, "2.2 GB", "#FF9500"],
    ["Slack", 9, "1.2 GB", "#AF52DE"],
    ["Terminal", 6, "640 MB", "#5B6275"],
    ["Mail", 5, "420 MB", "#30D158"],
    ["Music", 4, "310 MB", "#FF2D55"],
    ["macOS", 612, "3.9 GB", "#8E8E93"],
  ];

  const list = document.querySelector(".rows");
  const buttons = document.querySelectorAll(".switch button");
  let view = "processes";
  let busy = false;

  function row(markup, className, index) {
    const item = document.createElement("li");
    item.className = `row ${className}`;
    item.innerHTML = markup;
    if (!reduceMotion) {
      item.style.opacity = "0";
      item.style.transform = "translateY(10px)";
      item.style.transitionDelay = `${index * 45}ms`;
    }
    return item;
  }

  function render(next) {
    list.replaceChildren();
    if (next === "processes") {
      processes.forEach(([name, memory], index) => {
        list.append(row(
          `<span class="mark" aria-hidden="true"></span><span class="name">${name}</span><span class="figure">${memory}</span>`,
          "process", index));
      });
    } else {
      apps.forEach(([name, count, memory, color], index) => {
        const item = row(
          `<span class="mark" aria-hidden="true"></span><span class="name">${name}<span class="count">${count} processes</span></span><span class="figure">${memory}</span>`,
          "app", index);
        item.style.setProperty("--c", color);
        list.append(item);
      });
    }
    if (!reduceMotion) {
      // Next frame, so the transition starts from the offset state.
      requestAnimationFrame(() => requestAnimationFrame(() => {
        list.querySelectorAll(".row").forEach((item) => {
          item.style.opacity = "";
          item.style.transform = "";
        });
      }));
    }
  }

  function show(next) {
    if (next === view || busy) return;
    view = next;
    buttons.forEach((button) => button.setAttribute("aria-checked", String(button.dataset.view === next)));
    if (reduceMotion) {
      render(next);
      return;
    }
    busy = true;
    list.classList.add("leaving");
    setTimeout(() => {
      list.classList.remove("leaving");
      render(next);
      busy = false;
    }, 320);
  }

  buttons.forEach((button) => {
    button.addEventListener("click", () => show(button.dataset.view));
    button.addEventListener("keydown", (event) => {
      if (event.key !== "ArrowLeft" && event.key !== "ArrowRight") return;
      event.preventDefault();
      const other = [...buttons].find((candidate) => candidate !== button);
      other.focus();
      show(other.dataset.view);
    });
  });

  render("processes");
  // The page's one orchestrated moment: fold the list once, shortly after load.
  if (!reduceMotion) setTimeout(() => show("apps"), 1800);

  // ---------- The tour ----------

  const pages = {
    overview: {
      title: "Overview",
      text: "CPU, memory, GPU, disk, network and energy on one screen, each with a live graph, plus where your memory and power are going.",
      src: "assets/overview-light.webp",
      alt: "The Overview page: six metric cards with live graphs, memory by type, memory by app and power by app.",
    },
    cpu: {
      title: "CPU",
      text: "Load split into user and system, every core, today’s average and peak, and the apps behind it, one row each with its process count.",
      src: "assets/cpu-light.webp",
      alt: "The CPU page: load cards, a per-core chart, a live CPU graph and a table of apps with their process counts.",
    },
    memory: {
      title: "Memory",
      text: "The split macOS itself uses — app, wired, compressed, cached, free — plus pressure, swap and each app’s real footprint.",
      src: "assets/memory-light.webp",
      alt: "The Memory page: memory in use, a breakdown by type, swap, a memory graph and apps sorted by memory.",
    },
    projects: {
      title: "Projects",
      text: "Dev servers grouped by the project folder they run in, with their ports. Servers that have sat idle for hours are pointed out, and stopping them asks first.",
      src: "assets/projects-light.webp",
      alt: "The Projects page: an idle-servers banner and four projects with node and python servers, their ports and Stop buttons.",
    },
    sensors: {
      title: "Sensors",
      text: "CPU and GPU temperatures, fan speeds, and the battery of your AirPods, Magic Mouse, Keyboard and Trackpad.",
      src: "assets/sensors-light.webp",
      alt: "The Sensors page: CPU and GPU temperatures, fan speeds, a temperature chart and accessory batteries.",
    },
    menubar: {
      title: "Menu bar",
      text: "A compact dashboard one click from the menu bar: every metric with a small graph, the busiest apps right now, and a tab for each page.",
      src: "assets/popover-light.webp",
      alt: "The menu bar dashboard: CPU, memory, network, disk, GPU and battery rows with small graphs, and the busiest apps.",
      small: true,
    },
  };

  const pageButtons = document.querySelectorAll(".page");
  const title = document.getElementById("page-title");
  const text = document.getElementById("page-text");
  const shot = document.getElementById("page-shot");

  pageButtons.forEach((button) => {
    button.addEventListener("click", () => {
      const page = pages[button.dataset.page];
      pageButtons.forEach((other) => other.setAttribute("aria-pressed", String(other === button)));
      title.textContent = page.title;
      text.textContent = page.text;
      shot.src = page.src;
      shot.alt = page.alt;
      document.getElementById("page-shot-link").href = page.src;
      shot.closest(".shot").classList.toggle("small", Boolean(page.small));
    });
  });

  // Warm the tour images once the page is idle so switching is instant.
  window.addEventListener("load", () => {
    Object.values(pages).forEach((page) => { const image = new Image(); image.src = page.src; });
  });

  // ---------- Copy ----------

  document.querySelectorAll(".copy").forEach((button) => {
    button.addEventListener("click", async () => {
      const source = document.getElementById(button.dataset.copy);
      try {
        await navigator.clipboard.writeText(source.textContent.trim());
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select and copy";
      }
      setTimeout(() => { button.textContent = "Copy"; }, 1800);
    });
  });
})();
