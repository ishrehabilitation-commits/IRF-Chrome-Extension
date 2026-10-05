// IRF Minutes for WellSky — content script.
// Runs inside the WellSky tab, so API calls are same-origin and the browser
// attaches the session cookies automatically. Nothing leaves this browser.

(() => {
  if (window.__irfMinutesLoaded) return;
  window.__irfMinutesLoaded = true;

  // ------------------------------------------------------------------ //
  //  Settings                                                           //
  // ------------------------------------------------------------------ //

  const WEEKLY_TARGET_MIN = 900; // 15 hours per 7-day period from admission
  const CHARGE_CONCURRENCY = 4; // parallel charge requests; keep it gentle
  const DAY_MS = 86_400_000;
  const MINUTE_FIELDS = [
    ["CHRGINDV", "Individual"],
    ["CHRGGRP", "Group"],
    ["CHRGCOTR", "Cotreat"],
    ["CHRGSTAF", "Concurrent"],
  ];
  const TYPE_ORDER = MINUTE_FIELDS.map(([, type]) => type);
  const THERAPIST_FIELDS = ["CHRGENTRNAME", "CHRGENTRBY", "CHRGBY", "ENTERBY"];

  // ------------------------------------------------------------------ //
  //  Small helpers                                                      //
  // ------------------------------------------------------------------ //

  const esc = (s) =>
    String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const int = (v) => parseInt(v, 10) || 0;
  const sum = (arr) => arr.reduce((a, b) => a + b, 0);
  const zeros = () => Array(7).fill(0);
  const addInto = (target, src) => src.forEach((v, i) => (target[i] += v));

  // All date math in UTC midnight so DST never shifts a day.
  const parseYmd = (s) => {
    const m = /^(\d{4})(\d{2})(\d{2})$/.exec(String(s ?? ""));
    return m ? Date.UTC(+m[1], +m[2] - 1, +m[3]) : null;
  };
  const todayUtc = () => {
    const d = new Date();
    return Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
  };
  const todayYmd = () => {
    const d = new Date();
    return `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
  };
  const fmtMd = (t) => { const d = new Date(t); return `${d.getUTCMonth() + 1}/${d.getUTCDate()}`; };
  const fmtMdy = (t) => { const d = new Date(t); return `${d.getUTCMonth() + 1}/${d.getUTCDate()}/${d.getUTCFullYear()}`; };
  const fmtWeekday = (t) => new Date(t).toLocaleDateString("en-US", { weekday: "short", timeZone: "UTC" });

  async function mapLimit(items, limit, fn) {
    const out = new Array(items.length);
    let next = 0;
    const worker = async () => {
      while (next < items.length) {
        const i = next++;
        out[i] = await fn(items[i], i);
      }
    };
    await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
    return out;
  }

  // ------------------------------------------------------------------ //
  //  Domain logic (ported from IRFMinutesModule.py)                     //
  // ------------------------------------------------------------------ //

  const discipline = (desc) => /^(PT|OT|ST) /.exec(desc ?? "")?.[1] ?? null;

  const roomNumber = (r) => (r && r.length >= 4 ? r.slice(-4, -1) : r ?? "");

  const minutesByType = (c) => {
    const found = MINUTE_FIELDS.map(([f, type]) => [type, int(c[f])]).filter(([, m]) => m > 0);
    return found.length ? found : [["Individual", 0]];
  };

  const isZeroMinuteCharge = (c) => int(c.CHRGQTY) > 0 && MINUTE_FIELDS.every(([f]) => int(c[f]) === 0);

  const therapistName = (c) => {
    for (const f of THERAPIST_FIELDS) {
      const v = String(c[f] ?? "").trim();
      if (v && !["NONE", "N/A"].includes(v.toUpperCase())) return v;
    }
    return "Unknown";
  };

  const maxWeek = (admit) => Math.max(0, Math.floor((todayUtc() - admit) / DAY_MS / 7));

  const dayIndex = (admit, chargeYmd, week) => {
    const t = parseYmd(chargeYmd);
    if (t == null) return null;
    const delta = Math.round((t - admit) / DAY_MS) - week * 7;
    return delta >= 0 && delta < 7 ? delta : null;
  };

  // disc -> type -> charge description -> [7 daily minute totals]
  function summarizeWeek(charges, admit, week) {
    const tree = {};
    for (const c of charges) {
      const disc = discipline(c.CHRGDESC);
      if (!disc) continue;
      const di = dayIndex(admit, c.CHRGDATE, week);
      if (di == null) continue;
      for (const [type, mins] of minutesByType(c)) {
        const row = (((tree[disc] ??= {})[type] ??= {})[c.CHRGDESC] ??= zeros());
        row[di] += mins;
      }
    }
    return tree;
  }

  // ------------------------------------------------------------------ //
  //  WellSky API                                                        //
  // ------------------------------------------------------------------ //

  async function getSession() {
    const s = await chrome.runtime.sendMessage({ type: "irf:getSession" });
    if (!s?.token) throw new Error("No WellSky session found in this tab. Log in to WellSky, then load patients again.");
    return s;
  }

  async function callWellsky(name, data) {
    const res = await fetch(`${location.origin}/Interactant/get/${name}?t=${Date.now()}`, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json", Accept: "*/*" },
      body: JSON.stringify({ name, timeout: 90000, data }),
    });
    if (res.status === 401 || res.status === 403) {
      throw new Error("WellSky refused the request. Your session has likely expired; log in again.");
    }
    if (!res.ok) throw new Error(`${name} failed with HTTP ${res.status}.`);
    try {
      return await res.json();
    } catch {
      throw new Error(`${name} didn't return data. Your session may have expired; log in again.`);
    }
  }

  async function fetchPatients(userId, token, facility) {
    const json = await callWellsky("HOHSRCH", {
      USERID: userId, PASSWD: token, REQSEARCHTYPE: "C", REQLVL6: facility, REQUSER: userId,
      REQALERT: "", REQSEVR: "", REQCLASS: "", REQVIEW: "H", REQSEARCHBY: "A", REQNSTN: "",
      REQMEDCART: "", REQNAME: "", REQACCT: "", REQMRNO: "", REQDISCH: "N", REQDISCHDAY: "",
      REQACTIVE: "Y", REQPREADMIT: "N", REQINHOUSE: "Y", REQOUTPATIENT: "N", REQPHYTYPE: "A",
      INCLUDEPHOTO: "N",
    });
    return (json.GRIDDATA ?? []).filter((p) => p.GRIDCAT1 === "Inpatient Rehab");
  }

  async function fetchCharges(userId, token, facility, acct, admitYmd) {
    const json = await callWellsky("HOHCCHG", {
      USERID: userId, PASSWD: token, REQLV6: facility, REQACC: int(acct), REQDLT: "N",
      REQFDT: admitYmd, REQTDT: todayYmd(), REQIDX: "", REQPRC: "", REQPHY: "",
    });
    return (json.RECLIST ?? []).filter((c) => discipline(c.CHRGDESC));
  }

  // ------------------------------------------------------------------ //
  //  Panel (Shadow DOM keeps ExtJS styles and ours from colliding)      //
  // ------------------------------------------------------------------ //

  const host = document.createElement("div");
  host.id = "irf-minutes-host";
  host.style.cssText =
    "all:initial;position:fixed;top:0;right:0;height:100vh;z-index:2147483000;display:none;";
  // ExtJS listens for keys at the document level; keep our typing to ourselves.
  for (const type of ["keydown", "keyup", "keypress"]) host.addEventListener(type, (e) => e.stopPropagation());

  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `
    <link rel="stylesheet" href="${chrome.runtime.getURL("panel.css")}">
    <aside class="panel" aria-label="IRF therapy minutes">
      <header class="bar">
        <h1>IRF therapy minutes</h1>
        <button type="button" class="close" data-act="close" aria-label="Close panel">&times;</button>
      </header>
      <form class="controls">
        <label>User ID <input name="userId" autocomplete="off" spellcheck="false" required></label>
        <label>Facility <input name="facility" inputmode="numeric" pattern="\\d+" required></label>
        <button type="submit" class="primary">Load patients</button>
      </form>
      <p class="status" role="status"></p>
      <div class="tabs" role="tablist">
        <button type="button" role="tab" data-tab="minutes" aria-selected="true">Minutes</button>
        <button type="button" role="tab" data-tab="corrections" aria-selected="false">Missing minutes <span class="count"></span></button>
      </div>
      <div class="view" data-view="minutes">
        <p class="empty">Load patients to see each Inpatient Rehab patient's minutes for their current admission week.</p>
      </div>
      <div class="view" data-view="corrections" hidden>
        <p class="empty">Load patients to find PT, OT and ST charges that have a quantity but no minutes.</p>
      </div>
    </aside>`;
  document.documentElement.appendChild(host);

  const $ = (sel) => root.querySelector(sel);
  const form = $("form.controls");
  const loadBtn = form.querySelector("button[type=submit]");
  const minutesView = $('[data-view="minutes"]');
  const correctionsView = $('[data-view="corrections"]');

  const state = { patients: [], busy: false, settingsLoaded: false };

  function setStatus(text, isError = false) {
    const el = $(".status");
    el.textContent = text;
    el.classList.toggle("error", isError);
  }

  async function loadSettings() {
    if (state.settingsLoaded) return;
    const { userId = "", facility = "204" } = await chrome.storage.sync.get(["userId", "facility"]);
    form.userId.value = userId;
    form.facility.value = facility;
    state.settingsLoaded = true;
  }

  async function togglePanel(force) {
    const show = force ?? host.style.display === "none";
    host.style.display = show ? "block" : "none";
    if (show) {
      await loadSettings();
      (form.userId.value ? loadBtn : form.userId).focus();
    }
  }

  // ------------------------------------------------------------------ //
  //  Rendering                                                          //
  // ------------------------------------------------------------------ //

  const cells = (days) => {
    const total = sum(days);
    return days.map((v) => `<td>${v || ""}</td>`).join("") + `<td class="tot">${total || ""}</td>`;
  };

  function renderPatient(p, idx) {
    const { pat, charges, admit, week, maxWk, error, open } = p;
    const name = esc(pat.GRIDNAME);
    const room = esc(roomNumber(pat.GRIDROOM));

    if (admit == null) {
      return `<section class="patient" data-p="${idx}">
        <header class="who"><h2>${name}</h2><span class="meta">Room ${room}</span></header>
        <p class="note error">No admit date on file, so weeks can't be calculated.</p></section>`;
    }

    const start = admit + week * 7 * DAY_MS;
    const days = Array.from({ length: 7 }, (_, i) => start + i * DAY_MS);
    const tree = summarizeWeek(charges, admit, week);

    const overall = zeros();
    const discRows = Object.keys(tree).sort().map((disc) => {
      const discTotal = zeros();
      const childRows = [];
      for (const type of TYPE_ORDER) {
        const byDesc = tree[disc][type];
        if (!byDesc) continue;
        const typeTotal = zeros();
        Object.values(byDesc).forEach((r) => addInto(typeTotal, r));
        addInto(discTotal, typeTotal);
        childRows.push(`<tr class="row-type" data-of="${disc}"><th scope="row">${type}</th>${cells(typeTotal)}</tr>`);
        for (const desc of Object.keys(byDesc).sort()) {
          childRows.push(`<tr class="row-charge" data-of="${disc}"><th scope="row">${esc(desc)}</th>${cells(byDesc[desc])}</tr>`);
        }
      }
      addInto(overall, discTotal);
      const isOpen = open.has(disc);
      return `<tbody class="disc${isOpen ? " open" : ""}" data-disc="${disc}">
        <tr class="row-disc"><th scope="row">
          <button type="button" class="toggle" data-act="toggle" data-p="${idx}" data-disc="${disc}" aria-expanded="${isOpen}">${disc}</button>
        </th>${cells(discTotal)}</tr>
        ${childRows.join("")}
      </tbody>`;
    });

    const weekTotal = sum(overall);
    const isCurrent = week === maxWk;
    const daysLeft = isCurrent ? 6 - Math.round((todayUtc() - start) / DAY_MS) : 0;
    const met = weekTotal >= WEEKLY_TARGET_MIN;
    const meterClass = met ? "met" : isCurrent ? "pending" : "short";
    const meterNote = met
      ? "target met"
      : isCurrent
        ? `${WEEKLY_TARGET_MIN - weekTotal} to go, ${daysLeft} day${daysLeft === 1 ? "" : "s"} left`
        : `${WEEKLY_TARGET_MIN - weekTotal} short`;

    const body = discRows.length
      ? `<div class="scroll"><table>
          <thead><tr><th scope="col"><span class="sr">Discipline</span></th>
            ${days.map((t) => `<th scope="col">${fmtWeekday(t)}<span>${fmtMd(t)}</span></th>`).join("")}
            <th scope="col">Total</th></tr></thead>
          <tbody><tr class="row-total"><th scope="row">All therapy</th>${cells(overall)}</tr></tbody>
          ${discRows.join("")}
        </table></div>`
      : `<p class="note">No PT, OT or ST minutes charged this week.</p>`;

    return `<section class="patient" data-p="${idx}">
      <header class="who">
        <div>
          <h2>${name}</h2>
          <span class="meta">Room ${room}</span><span class="meta">Admitted ${fmtMdy(admit)}</span>
        </div>
        <div class="weeknav">
          <button type="button" data-act="week" data-p="${idx}" data-dir="-1" ${week === 0 ? "disabled" : ""} aria-label="Previous week">&lsaquo;</button>
          <span>Week ${week + 1} of ${maxWk + 1}<small>${fmtMd(days[0])} – ${fmtMd(days[6])}</small></span>
          <button type="button" data-act="week" data-p="${idx}" data-dir="1" ${isCurrent ? "disabled" : ""} aria-label="Next week">&rsaquo;</button>
        </div>
      </header>
      <div class="meter ${meterClass}">
        <div class="track" role="meter" aria-valuemin="0" aria-valuemax="${WEEKLY_TARGET_MIN}" aria-valuenow="${weekTotal}"
             aria-label="Minutes this week toward ${WEEKLY_TARGET_MIN}">
          <div class="fill" style="width:${Math.min(100, (weekTotal / WEEKLY_TARGET_MIN) * 100)}%"></div>
        </div>
        <span><strong>${weekTotal}</strong> of ${WEEKLY_TARGET_MIN} min, ${meterNote}</span>
      </div>
      ${error ? `<p class="note error">Charges didn't load: ${esc(error)}</p>` : ""}
      ${body}
    </section>`;
  }

  function renderMinutes() {
    minutesView.innerHTML = state.patients.length
      ? state.patients.map(renderPatient).join("")
      : `<p class="empty">No Inpatient Rehab patients are in house for this facility.</p>`;
  }

  function rerenderPatient(idx) {
    const el = minutesView.querySelector(`section[data-p="${idx}"]`);
    if (el) el.outerHTML = renderPatient(state.patients[idx], idx);
  }

  function renderCorrections() {
    const byTherapist = new Map();
    let count = 0;
    for (const { pat, charges } of state.patients) {
      for (const c of charges) {
        if (!isZeroMinuteCharge(c)) continue;
        count++;
        const t = therapistName(c);
        if (!byTherapist.has(t)) byTherapist.set(t, new Map());
        const byPatient = byTherapist.get(t);
        const pname = pat.GRIDNAME ?? "Unknown patient";
        if (!byPatient.has(pname)) byPatient.set(pname, []);
        byPatient.get(pname).push(c);
      }
    }

    $(".count").textContent = count ? `(${count})` : "";

    if (!count) {
      correctionsView.innerHTML = `<p class="empty">Every PT, OT and ST charge has minutes recorded.</p>`;
      return;
    }

    const byName = (a, b) => a.localeCompare(b);
    correctionsView.innerHTML = [...byTherapist.keys()].sort(byName).map((therapist) => {
      const byPatient = byTherapist.get(therapist);
      const n = sum([...byPatient.values()].map((l) => l.length));
      return `<section class="therapist">
        <h2>${esc(therapist)} <span>${n} charge${n === 1 ? "" : "s"}</span></h2>
        ${[...byPatient.keys()].sort(byName).map((pname) => `
          <h3>${esc(pname)}</h3>
          <table class="fixes">
            <thead><tr><th scope="col">Date</th><th scope="col">Charge</th><th scope="col">Qty</th></tr></thead>
            <tbody>${byPatient.get(pname)
              .sort((a, b) => String(a.CHRGDATE).localeCompare(String(b.CHRGDATE)))
              .map((c) => {
                const t = parseYmd(c.CHRGDATE);
                return `<tr><td>${t == null ? esc(c.CHRGDATE) : fmtMdy(t)}</td><td>${esc(c.CHRGDESC)}</td><td>${int(c.CHRGQTY)}</td></tr>`;
              }).join("")}</tbody>
          </table>`).join("")}
      </section>`;
    }).join("");
  }

  // ------------------------------------------------------------------ //
  //  Loading                                                            //
  // ------------------------------------------------------------------ //

  async function load() {
    if (state.busy) return;
    const userId = form.userId.value.trim();
    const facility = form.facility.value.trim();
    chrome.storage.sync.set({ userId, facility });

    state.busy = true;
    loadBtn.disabled = true;
    try {
      setStatus("Checking your WellSky session…");
      const { token } = await getSession();

      setStatus("Loading patient list…");
      const pats = await fetchPatients(userId, token, int(facility));

      let done = 0;
      state.patients = await mapLimit(pats, CHARGE_CONCURRENCY, async (pat) => {
        let charges = [];
        let error = null;
        try {
          charges = await fetchCharges(userId, token, int(facility), pat.GRIDACCT, pat.GRIDADMIT);
        } catch (err) {
          error = err.message;
        }
        setStatus(`Loading charges for patient ${++done} of ${pats.length}…`);
        const admit = parseYmd(pat.GRIDADMIT);
        const maxWk = admit == null ? 0 : maxWeek(admit);
        // Start on the most recent week, like the desktop version did.
        return { pat, charges, error, admit, maxWk, week: maxWk, open: new Set() };
      });

      renderMinutes();
      renderCorrections();
      const failed = state.patients.filter((p) => p.error).length;
      const time = new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
      setStatus(
        `Loaded ${state.patients.length} patient${state.patients.length === 1 ? "" : "s"} at ${time}.` +
          (failed ? ` Charges failed for ${failed}; see the notes below.` : ""),
        failed > 0,
      );
    } catch (err) {
      setStatus(err.message, true);
    } finally {
      state.busy = false;
      loadBtn.disabled = false;
    }
  }

  // ------------------------------------------------------------------ //
  //  Events                                                             //
  // ------------------------------------------------------------------ //

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    load();
  });

  root.addEventListener("click", (e) => {
    const btn = e.target.closest("button[data-act], button[data-tab]");
    if (!btn) return;

    if (btn.dataset.tab) {
      for (const tab of root.querySelectorAll("[role=tab]")) tab.setAttribute("aria-selected", tab === btn);
      for (const view of root.querySelectorAll(".view")) view.hidden = view.dataset.view !== btn.dataset.tab;
      return;
    }

    const idx = int(btn.dataset.p);
    const p = state.patients[idx];
    switch (btn.dataset.act) {
      case "close":
        togglePanel(false);
        break;
      case "week":
        p.week = Math.max(0, Math.min(p.maxWk, p.week + int(btn.dataset.dir)));
        rerenderPatient(idx);
        root.querySelector(`section[data-p="${idx}"] button[data-dir="${btn.dataset.dir}"]:not([disabled])`)?.focus();
        break;
      case "toggle": {
        const disc = btn.dataset.disc;
        p.open.has(disc) ? p.open.delete(disc) : p.open.add(disc);
        const isOpen = p.open.has(disc);
        btn.closest("tbody").classList.toggle("open", isOpen);
        btn.setAttribute("aria-expanded", isOpen);
        break;
      }
    }
  });

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.type === "irf:toggle") togglePanel();
  });
})();
