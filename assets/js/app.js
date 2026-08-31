import "phoenix_html";
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";

const framed = window.self !== window.top;
const shellOrigins = window.__thorShellOrigins || [];
// Never "*": these messages can carry tokens; address the shell exactly.
const shellOrigin = shellOrigins[0];

const postToShell = (msg) => {
  if (!framed || !shellOrigin) return;
  for (const origin of shellOrigins) {
    try {
      window.parent.postMessage(msg, origin);
    } catch (_e) {
      /* the non-matching origin throws or drops — fine */
    }
  }
};

const reportNav = () => {
  postToShell({
    type: "thor.nav.state",
    path: window.location.pathname + window.location.search,
    canBack: window.history.length > 1,
    canForward: false,
  });
};

// Shell-driven navigation: back/forward/goto from the shell's nav chrome.
window.addEventListener("message", (e) => {
  if (!shellOrigins.includes(e.origin) || !e.data || e.data.type !== "thor.nav.command") return;
  const { action, path } = e.data;
  if (action === "back") window.history.back();
  else if (action === "forward") window.history.forward();
  else if (action === "goto" && typeof path === "string") {
    window.liveSocket ? window.liveSocket.pushHistoryPatch(path, "push") : (window.location.href = path);
  }
});

const Hooks = {
  ThorBridge: {
    mounted() {
      reportNav();
    },
    updated() {
      reportNav();
    },
  },
  // "Copy table" — writes the TSV payload carried in a data attribute.
  CopyPayload: {
    mounted() {
      this.el.addEventListener("click", () => {
        const source = document.getElementById(this.el.dataset.source);
        const text = source ? source.value || source.textContent : "";
        navigator.clipboard
          .writeText(text)
          .then(() => {
            this.el.dataset.copied = "1";
            setTimeout(() => delete this.el.dataset.copied, 1600);
          })
          .catch(() => {});
      });
    },
  },
  // CSV download built client-side from an embedded payload (no server round-trip).
  DownloadPayload: {
    mounted() {
      this.el.addEventListener("click", () => {
        const source = document.getElementById(this.el.dataset.source);
        if (!source) return;
        const blob = new Blob(["﻿" + (source.value || source.textContent)], {
          type: "text/csv;charset=utf-8;",
        });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = this.el.dataset.filename || "export.csv";
        a.click();
        URL.revokeObjectURL(url);
      });
    },
  },
  PrintPage: {
    mounted() {
      this.el.addEventListener("click", () => window.print());
    },
  },
  // Hover callout for the daily chart: each day has a transparent hit area
  // ([data-day]) and a pre-rendered <template data-tip-for>; the hook copies
  // the template into one floating box and follows the cursor. Tap toggles
  // on touch. No server round-trip.
  ChartTooltip: {
    mounted() {
      this.current = null;
      this.bind();
    },
    updated() {
      this.current = null;
      this.bind();
    },
    bind() {
      const el = this.el;
      const box = el.querySelector("[data-tip-box]");
      if (!box) return;
      const hide = () => {
        box.hidden = true;
        this.current = null;
      };
      const show = (day, evt) => {
        const src = el.querySelector(`[data-tip-for="${day}"]`);
        if (!src) return;
        if (this.current !== day) {
          box.innerHTML = src.innerHTML;
          this.current = day;
        }
        box.hidden = false;
        const r = el.getBoundingClientRect();
        let x = evt.clientX - r.left + 14;
        let y = evt.clientY - r.top + 14;
        const bw = box.offsetWidth;
        const bh = box.offsetHeight;
        if (x + bw > r.width - 4) x = evt.clientX - r.left - bw - 14;
        if (x < 4) x = 4;
        if (y + bh > r.height - 4) y = Math.max(4, evt.clientY - r.top - bh - 14);
        box.style.left = `${x}px`;
        box.style.top = `${y}px`;
      };
      el.querySelectorAll("[data-day]").forEach((hit) => {
        hit.onmousemove = (e) => show(hit.dataset.day, e);
        hit.onmouseleave = hide;
        hit.onclick = (e) => {
          if (this.current === hit.dataset.day && !box.hidden) hide();
          else show(hit.dataset.day, e);
        };
      });
      el.onmouseleave = hide;
    },
  },
  // Standalone theme control (hidden when framed — the shell owns theme there).
  ThemeToggle: {
    mounted() {
      if (framed) return; // the shell owns theme when framed; the control is hidden anyway
      const html = document.documentElement;
      const apply = (choice) => {
        const resolved =
          choice === "auto"
            ? window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
            : choice;
        html.setAttribute("data-theme", resolved);
        try { localStorage.setItem("gmbmd:theme", choice); } catch (_e) {}
        this.el.querySelectorAll("[data-theme-choice]").forEach((b) => {
          const on = b.dataset.themeChoice === choice;
          b.classList.toggle("bg-navy", on);
          b.classList.toggle("text-navy-content", on);
          b.classList.toggle("text-muted", !on);
          b.setAttribute("aria-pressed", String(on));
        });
      };
      let current = "light";
      try { current = localStorage.getItem("gmbmd:theme") || "light"; } catch (_e) {}
      apply(current);
      this.el.querySelectorAll("[data-theme-choice]").forEach((b) =>
        b.addEventListener("click", () => apply(b.dataset.themeChoice))
      );
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
        let c = "light";
        try { c = localStorage.getItem("gmbmd:theme") || "light"; } catch (_e) {}
        if (c === "auto") apply("auto");
      });
    },
  },
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

window.addEventListener("phx:page-loading-stop", reportNav);

liveSocket.connect();
window.liveSocket = liveSocket;
