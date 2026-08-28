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
};

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  params: { _csrf_token: csrfToken },
  hooks: Hooks,
});

window.addEventListener("phx:page-loading-stop", reportNav);

liveSocket.connect();
window.liveSocket = liveSocket;
