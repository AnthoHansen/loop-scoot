(() => {
  const resource = typeof GetParentResourceName === "function" ? GetParentResourceName() : "loop-scoot";
  const root = document.createElement("div");
  root.id = "lo-overlay";
  document.body.appendChild(root);

  const post = (name, data) =>
    fetch(`https://${resource}/${name}`, {
      method: "POST",
      headers: { "Content-Type": "application/json; charset=UTF-8" },
      body: JSON.stringify(data || {}),
    }).catch(() => {});

  const esc = (v) => String(v ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  const MOUSE = (button) =>
    `<svg viewBox="0 0 17 22" fill="none"><rect x="1" y="1" width="15" height="20" rx="7.5" stroke="currentColor" stroke-width="1.6"/>` +
    (button === 3 ? `<rect x="7.2" y="4.5" width="2.6" height="5" rx="1.3" fill="currentColor"/>` :
      `<path d="${button === 1 ? "M8.5 1.8V9.5H1.8" : "M8.5 1.8V9.5H15.2"}" stroke="currentColor" stroke-width="1.6"/>` +
      `<path d="${button === 1 ? "M8.5 1.8A6.7 6.7 0 0 0 1.8 8.5V9.5H8.5Z" : "M8.5 1.8A6.7 6.7 0 0 1 15.2 8.5V9.5H8.5Z"}" fill="currentColor"/>`) +
    `</svg>`;

  const cap = (key) => {
    const k = String(key || "E").toUpperCase();
    const m = /^M([123])$/.exec(k);
    if (m) return `<span class="lo-cap bare">${MOUSE(Number(m[1]))}</span>`;
    return `<span class="lo-cap${k.length > 2 ? " wide" : ""}">${esc(k)}</span>`;
  };

  const HALF = 10.5;
  const interact = { el: null, label: null, samples: [], raf: 0, offset: null, delay: 50, id: "" };

  const place = (x, y, s) => {
    if (!interact.el) return;
    const u = window.innerHeight / 1080;
    const left = x * window.innerWidth - HALF * u;
    const top = y * window.innerHeight - HALF * u;
    interact.el.style.transform = `translate3d(${left}px, ${top}px, 0) scale(${s})`;
  };

  const loop = (now) => {
    const e = interact.samples;
    const t = now - interact.delay;
    let p = e[e.length - 1];
    if (e.length && t <= e[0].t) p = e[0];
    else
      for (let i = e.length - 1; i > 0; i--) {
        const a = e[i - 1], b = e[i];
        if (t >= a.t && t <= b.t) {
          const k = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1;
          p = { x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, s: a.s + (b.s - a.s) * k };
          break;
        }
      }
    if (p) place(p.x, p.y, p.s);
    const last = e[e.length - 1];
    interact.raf = last && t < last.t ? requestAnimationFrame(loop) : 0;
  };

  const sample = (x, y, s, tGame) => {
    const now = performance.now();
    let t = now;
    if (typeof tGame === "number") {
      const raw = now - tGame;
      interact.offset = interact.offset === null ? raw : Math.min(interact.offset + 0.1, raw);
      t = tGame + interact.offset;
    }
    const e = interact.samples;
    const last = e[e.length - 1];
    if (last && t <= last.t) t = last.t + 1;
    e.push({ t, x, y, s: Math.min(1, Math.max(0.01, Number(s) || 1)) });
    if (e.length > 8) e.splice(0, e.length - 8);
    if (!interact.raf) interact.raf = requestAnimationFrame(loop);
  };

  const hideInteract = (fade) => {
    const el = interact.el;
    if (!el) return;
    interact.el = null;
    interact.id = "";
    interact.samples = [];
    if (interact.raf) cancelAnimationFrame(interact.raf);
    interact.raf = 0;
    const label = el.firstChild;
    if (label) label.classList.remove("on");
    setTimeout(() => el.remove(), (fade || 183) + 16);
  };

  const showInteract = (d) => {
    if (!d.visible) return hideInteract(d.fade);
    const html = `<div class="lo-label" style="transition-duration:${d.fade || 183}ms"><span class="lo-key">${esc(d.key || "E")}</span><span class="lo-text">${esc(d.label || "INTERACT")}</span></div>`;
    if (interact.el && interact.id === d.id) {
      interact.el.innerHTML = html;
      interact.el.firstChild.classList.add("on");
      sample(d.x, d.y, d.scale, d.t);
      return;
    }
    hideInteract(d.fade);
    const el = document.createElement("div");
    el.className = "lo-anchor";
    el.style.transformOrigin = `${HALF * (window.innerHeight / 1080)}px ${HALF * (window.innerHeight / 1080)}px`;
    el.innerHTML = html;
    root.appendChild(el);
    interact.el = el;
    interact.id = d.id || "";
    interact.samples = [];
    interact.offset = null;
    place(d.x, d.y, Math.min(1, Number(d.scale) || 1));
    sample(d.x, d.y, d.scale, d.t);
    requestAnimationFrame(() => el.firstChild && el.firstChild.classList.add("on"));
  };

  let bar = null;
  let barSignature = "";
  const renderBar = (items, parent) =>
    `<div class="lo-bar">${items
      .map((it, i) => `<span class="lo-group">${i > 0 ? '<i class="lo-slash"></i>' : ""}${cap(it.key)}<span class="lo-lbl">${esc(it.label)}</span></span>`)
      .join("")}</div>`;

  const setPrompts = (items) => {
    const list = Array.isArray(items) ? items.filter((it) => it && it.label) : [];
    const signature = JSON.stringify(list);
    if (signature === barSignature) return;
    barSignature = signature;
    if (bar) {
      const old = bar;
      bar = null;
      old.classList.add("out");
      setTimeout(() => old.remove(), 150);
    }
    if (!list.length) return;
    const holder = document.createElement("div");
    holder.innerHTML = renderBar(list);
    bar = holder.firstChild;
    root.appendChild(bar);
  };

  const dialogue = { el: null, state: null, index: -1 };

  const renderDialogue = () => {
    const s = dialogue.state;
    if (!s || !s.open) {
      if (dialogue.el) dialogue.el.remove();
      dialogue.el = null;
      return;
    }
    if (!dialogue.el) {
      dialogue.el = document.createElement("div");
      dialogue.el.className = "lo-dialogue";
      root.appendChild(dialogue.el);
    }
    const choices = Array.isArray(s.choices) ? s.choices : [];
    const n = choices.length;
    const t = s.text || {};
    dialogue.el.innerHTML =
      `<header class="lo-who"><h1 class="lo-name">${esc(s.name)}</h1>${s.role ? `<h2 class="lo-role">${esc(s.role)}</h2>` : ""}</header>` +
      `<nav class="lo-choices" style="top:calc(var(--u) * ${519.5 - (n - 1) * 48})">` +
      choices
        .map((c, i) => `<button type="button" class="lo-choice${i === dialogue.index ? " active" : ""}" data-i="${i}"${s.busy ? " disabled" : ""}><span>${esc(c.label)}</span></button>`)
        .join("") +
      `</nav>` +
      (s.line ? `<div class="lo-band"><p class="lo-line">${esc(s.line)}</p></div>` : "") +
      renderBar([
        { key: "↕", label: t.move || "Move" },
        { key: "↵", label: t.select || "Select" },
        { key: "ESC", label: t.back || "Back" },
      ]);
    dialogue.el.querySelectorAll(".lo-choice").forEach((b) => {
      const i = Number(b.dataset.i);
      b.addEventListener("mouseenter", () => {
        if (dialogue.index !== i) {
          dialogue.index = i;
          renderDialogue();
        }
      });
      b.addEventListener("click", () => choose(i));
    });
  };

  const choose = (i) => {
    const s = dialogue.state;
    if (!s || !s.open || s.busy) return;
    const c = (s.choices || [])[i];
    if (c) post("loop:dialogue:choose", { id: c.id });
  };

  window.addEventListener("keydown", (e) => {
    const s = dialogue.state;
    if (!s || !s.open) return;
    const n = (s.choices || []).length;
    if (e.key === "Escape" || e.key === "Backspace") {
      post("loop:dialogue:close", {});
      return;
    }
    if (!n || s.busy) return;
    if (e.key === "ArrowDown") dialogue.index = dialogue.index < 0 ? 0 : (dialogue.index + 1) % n;
    else if (e.key === "ArrowUp") dialogue.index = dialogue.index < 0 ? n - 1 : (dialogue.index - 1 + n) % n;
    else if (e.key === "Enter" && dialogue.index >= 0) return choose(dialogue.index);
    else return;
    renderDialogue();
  });

  const GLYPH_BANG = '<svg viewBox="0 0 34 34" aria-hidden="true"><rect x="14" y="0.5" width="6" height="23" rx="3" fill="currentColor"/><circle cx="17" cy="30" r="3" fill="currentColor"/></svg>';
  const GLYPH_TRIANGLE = '<svg viewBox="0 0 34 34" aria-hidden="true"><path d="M16.5 9 26.5 26H6.5Z" fill="currentColor" stroke="currentColor" stroke-width="4" stroke-linejoin="round"/><rect x="15" y="13.5" width="3" height="7.5" rx="1.5" fill="rgba(12, 12, 12, 0.3)"/><circle cx="16.5" cy="23.2" r="1.5" fill="rgba(12, 12, 12, 0.3)"/></svg>';
  const TOAST_KINDS = { success: 1, error: 1, warn: 1, info: 1 };
  const TOAST_MAX = 4;
  const TOAST_OUT_MS = 183;
  const toasts = { stack: null, list: [] };

  const dropToast = (t) => {
    clearTimeout(t.timer);
    clearTimeout(t.exit);
    t.el.remove();
    const i = toasts.list.indexOf(t);
    if (i >= 0) toasts.list.splice(i, 1);
  };

  const leaveToast = (t) => {
    clearTimeout(t.timer);
    if (t.leaving) return;
    t.leaving = true;
    t.el.classList.add("out");
    t.exit = setTimeout(() => dropToast(t), TOAST_OUT_MS);
  };

  const showToast = (d) => {
    if (!toasts.stack) {
      toasts.stack = document.createElement("div");
      toasts.stack.className = "lo-toasts";
      root.appendChild(toasts.stack);
    }
    const id = String(d.id ?? "");
    const same = toasts.list.find((t) => t.id === id);
    if (same) dropToast(same);
    const kind = TOAST_KINDS[d.kind] ? d.kind : "info";
    const el = document.createElement("article");
    el.className = `lo-toast ${kind}`;
    el.innerHTML =
      `<span class="lo-tile">${kind === "warn" || kind === "error" ? GLYPH_TRIANGLE : GLYPH_BANG}</span>` +
      `<span class="lo-tbody"><b class="lo-ttitle">${esc(d.title)}</b>${d.sub ? `<i class="lo-tsub">${esc(d.sub)}</i>` : ""}</span>`;
    toasts.stack.prepend(el);
    const t = { id, el, timer: 0, exit: 0, leaving: false };
    toasts.list.unshift(t);
    while (toasts.list.length > TOAST_MAX) dropToast(toasts.list[toasts.list.length - 1]);
    t.timer = setTimeout(() => leaveToast(t), Number(d.duration) > 0 ? Number(d.duration) : 5000);
  };

  const progress = { el: null, fill: null, raf: 0, startedAt: 0, duration: 0 };

  const stopProgress = () => {
    if (progress.raf) cancelAnimationFrame(progress.raf);
    progress.raf = 0;
    if (progress.el) progress.el.remove();
    progress.el = null;
    progress.fill = null;
  };

  const startProgress = (d) => {
    stopProgress();
    const el = document.createElement("div");
    el.className = "lo-progress";
    const key = String(d.cancelKey || "ESC").toUpperCase();
    el.innerHTML =
      `<div class="lo-pblock"><span class="lo-plabel">${esc(d.label)}</span><i class="lo-ptrack"><b></b></i></div>` +
      (d.cancellable
        ? `<div class="lo-pcancel"><span class="lo-group"><span class="lo-cap${key.length > 2 ? " wide" : ""}"><span class="lo-cap-text">${esc(key)}</span></span><span class="lo-lbl">${esc(d.cancelLabel || "Cancel")}</span></span></div>`
        : "");
    root.appendChild(el);
    progress.el = el;
    progress.fill = el.querySelector(".lo-ptrack b");
    progress.duration = Math.max(1, Number(d.duration) || 1);
    progress.startedAt = performance.now();
    const tick = () => {
      if (!progress.el) return;
      const r = Math.min(1, Math.max(0, (performance.now() - progress.startedAt) / progress.duration));
      progress.fill.style.width = `${r * 100}%`;
      progress.raf = r < 1 ? requestAnimationFrame(tick) : 0;
    };
    progress.raf = requestAnimationFrame(tick);
  };

  window.addEventListener("message", (event) => {
    const d = event.data;
    if (!d || typeof d.action !== "string" || d.action.slice(0, 5) !== "loop:") return;
    if (d.action === "loop:notify") showToast(d);
    else if (d.action === "loop:progress") {
      if (d.open) startProgress(d);
      else stopProgress();
    } else if (d.action === "loop:interact") showInteract(d);
    else if (d.action === "loop:interact:pos") {
      if (interact.el) sample(d.x, d.y, d.scale, d.t);
    } else if (d.action === "loop:prompts") setPrompts(d.items);
    else if (d.action === "loop:dialogue") {
      const wasOpen = dialogue.state && dialogue.state.open;
      dialogue.state = d.state || { open: false };
      if (!dialogue.state.open || !wasOpen) dialogue.index = -1;
      if (typeof dialogue.state.index === "number") dialogue.index = dialogue.state.index;
      if (dialogue.index >= (dialogue.state.choices || []).length) dialogue.index = -1;
      renderDialogue();
    }
  });
})();
