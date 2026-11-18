// InstaBox keepalive for Cloudflare Workers.
//
// Same job as instabox-keepalive.sh, without a machine of your own: a Cron
// Trigger fires every 5 minutes and renews the activity lease of every machine
// on every API key. InstaBox only pauses a machine after 30 idle minutes, so
// this keeps them running around the clock.
//
// Setup (dashboard, no CLI needed):
//   1. Workers & Pages -> Create -> Worker -> paste this file -> Deploy
//   2. Settings -> Variables and Secrets:
//        INSTABOX_API_KEY   Secret   ibk_...   (more keys: comma separated, or _2, _3)
//        TOKEN              Secret   a random string you choose
//        INSTABOX_LEASE_TTL Text     900       (must be longer than the cron gap)
//   3. Settings -> Triggers -> Cron Triggers -> */5 * * * *
//   4. Open /status?token=... to check it.
//
//   Optional:
//     INSTABOX_MACHINE       Text   only these machines (comma separated)
//     INSTABOX_ROTATE        Text   0 disables the pre-cap suspend/resume
//     INSTABOX_ROTATE_MARGIN_MIN Text  10  minutes of run left to rotate at
//     INSTABOX_LOG_MODE      Text   hourly / every / off
//     LOG                    KV binding, optional, keeps a /log of the last 48 runs

const DEFAULTS = {
  apiUrl: "https://api.instabox.sh",
  lease: "keepalive",
  ttl: 900,
  rotateMargin: 10,
  autoResume: true,
};

const json = (data, status = 200) =>
  new Response(JSON.stringify(data, null, 2) + "\n", {
    status,
    headers: { "Content-Type": "application/json; charset=utf-8" },
  });

const text = (body, status = 200) =>
  new Response(body.endsWith("\n") ? body : body + "\n", {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8" },
  });

function config(env) {
  const ttl = Number.parseInt(env.INSTABOX_LEASE_TTL ?? "", 10);
  const margin = Number.parseInt(env.INSTABOX_ROTATE_MARGIN_MIN ?? "", 10);
  return {
    apiUrl: (env.INSTABOX_API_URL || DEFAULTS.apiUrl).replace(/\/+$/, ""),
    lease: env.INSTABOX_LEASE || DEFAULTS.lease,
    ttl: Number.isFinite(ttl) && ttl >= 30 && ttl <= 3600 ? ttl : DEFAULTS.ttl,
    autoResume: !["0", "false", "no", "off"].includes(String(env.INSTABOX_AUTO_RESUME ?? "1").toLowerCase()),
    rotate: !["0", "false", "no", "off"].includes(String(env.INSTABOX_ROTATE ?? "1").toLowerCase()),
    rotateMargin: Number.isFinite(margin) && margin > 0 ? Math.min(margin, 120) : DEFAULTS.rotateMargin,
    logMode: (env.INSTABOX_LOG_MODE || "hourly").toLowerCase(),
  };
}

function accounts(env) {
  const seen = new Set();
  const out = [];
  const add = (raw) => {
    if (!raw) return;
    for (const piece of String(raw).split(",")) {
      const key = piece.trim();
      if (!key || seen.has(key)) continue;
      seen.add(key);
      out.push({ key });
    }
  };
  add(env.INSTABOX_API_KEY);
  for (let i = 2; i <= 10; i++) add(env[`INSTABOX_API_KEY_${i}`]);
  // Account numbers are the order shown by /accounts. A per-account filter is
  // INSTABOX_MACHINE_<that number>; otherwise INSTABOX_MACHINE applies to all.
  return out.map((a, i) => {
    const n = i + 1;
    return { ...a, n, machine: (env[`INSTABOX_MACHINE_${n}`] ?? env.INSTABOX_MACHINE ?? "").trim() };
  });
}

async function api(cfg, account, method, path, body) {
  const headers = { "X-API-Key": account.key };
  const init = {
    method,
    headers,
    signal: AbortSignal.timeout(method === "GET" ? 30000 : 60000),
  };
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    init.body = JSON.stringify(body);
  }
  if (method !== "GET") {
    headers["Idempotency-Key"] = `ka-${method.toLowerCase()}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
  }
  const res = await fetch(cfg.apiUrl + path, init);
  const raw = await res.text();
  let data = null;
  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {
    /* keep raw */
  }
  return { status: res.status, ok: res.ok, data, raw, retryAfter: res.headers.get("Retry-After") };
}

async function listMachines(cfg, account) {
  const all = [];
  let cursor = null;
  for (let page = 0; page < 5; page++) {
    const qs = cursor ? `?cursor=${encodeURIComponent(cursor)}` : "";
    const r = await api(cfg, account, "GET", `/v1/machines${qs}`);
    if (!r.ok) return { ok: false, error: describe(r) };
    const batch = Array.isArray(r.data?.machines) ? r.data.machines : [];
    all.push(...batch);
    cursor = r.data?.nextCursor ?? null;
    if (!cursor || batch.length === 0) break;
  }
  return { ok: true, machines: all };
}

function describe(r) {
  const e = r.data?.error;
  const msg = e?.message || r.raw || "no response";
  return `HTTP ${r.status} ${e?.code || ""}: ${msg}`.replace(/\s+/g, " ").slice(0, 240);
}

function pickMachines(machines, filter) {
  if (!filter || filter.toLowerCase() === "all") return machines;
  const wants = filter.split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
  return machines.filter((m) => {
    const id = String(m.id || "").toLowerCase();
    const name = String(m.name || "").toLowerCase();
    return wants.includes(id) || wants.includes(name);
  });
}

async function renewOne(cfg, account, machine) {
  const id = machine.id;
  const name = machine.name || id;
  const put = () =>
    api(cfg, account, "PUT", `/v1/machines/${encodeURIComponent(id)}/activity-leases/${encodeURIComponent(cfg.lease)}`, {
      ttlSeconds: cfg.ttl,
    });

  let r = await put();
  if (r.ok) return { name, renewed: true, expiresAt: r.data?.expiresAt ?? null };

  const code = r.data?.error?.code || "";
  if (r.status === 409 && code === "machine_cooldown") {
    return { name, renewed: false, skipped: "cooldown", retryAfter: r.retryAfter };
  }

  if (cfg.autoResume && r.status === 409 && ["machine_not_running", "operation_conflict"].includes(code)) {
    // A lease normally wakes an idle-paused machine by itself. This path is for
    // machines paused or stopped by hand, where the lease is refused instead.
    const wake = await api(cfg, account, "POST", `/v1/machines/${encodeURIComponent(id)}/wake`);
    if (!wake.ok) {
      await api(cfg, account, "POST", `/v1/machines/${encodeURIComponent(id)}/resume`);
      await api(cfg, account, "POST", `/v1/machines/${encodeURIComponent(id)}/start`);
    }
    r = await put();
    if (r.ok) return { name, renewed: true, expiresAt: r.data?.expiresAt ?? null, woke: true };
    if (r.status === 409 && (r.data?.error?.code || "") === "machine_cooldown") {
      return { name, renewed: false, skipped: "cooldown", retryAfter: r.retryAfter };
    }
  }
  return { name, renewed: false, error: describe(r) };
}

async function machineDetail(cfg, account, id) {
  return api(cfg, account, "GET", `/v1/machines/${encodeURIComponent(id)}`);
}

async function waitForState(cfg, account, id, want, seconds) {
  for (let i = 0; i < seconds; i++) {
    await new Promise((resolve) => setTimeout(resolve, 1000));
    const r = await machineDetail(cfg, account, id);
    if (r.ok && r.data?.state === want) return true;
  }
  return false;
}

// The lease prevents the idle pause, not the plan's max-run cap. When a run is
// about to reach it, suspend and resume at once: that starts a fresh run, so
// the platform never pauses the machine itself (and never starts a cooldown).
async function maybeRotate(cfg, account, machine) {
  if (!cfg.rotate) return null;
  const detail = await machineDetail(cfg, account, machine.id);
  if (!detail.ok) return null;
  const m = detail.data || {};
  if (m.state !== "running") return null;
  const maxRun = Number(m.maxRunMinutes);
  if (!Number.isFinite(maxRun) || maxRun <= 0) return null;
  if (m.cooldownUntil && Date.parse(m.cooldownUntil) > Date.now()) return null;
  const started = Date.parse(m.runStartedAt || "");
  if (!Number.isFinite(started)) return null;
  const remainMinutes = (started + maxRun * 60000 - Date.now()) / 60000;
  if (remainMinutes > cfg.rotateMargin) return null;

  const t0 = Date.now();
  const id = encodeURIComponent(machine.id);
  const suspended = await api(cfg, account, "POST", `/v1/machines/${id}/suspend`);
  if (!suspended.ok) return { rotated: false, error: describe(suspended) };
  if (!(await waitForState(cfg, account, machine.id, "suspended", 20))) {
    return { rotated: false, error: "did not reach suspended" };
  }
  const resumed = await api(cfg, account, "POST", `/v1/machines/${id}/resume`);
  if (!resumed.ok) await api(cfg, account, "POST", `/v1/machines/${id}/start`);
  if (!(await waitForState(cfg, account, machine.id, "running", 40))) {
    return { rotated: false, error: "did not come back running" };
  }
  return { rotated: true, downtimeSeconds: Math.round((Date.now() - t0) / 1000) };
}

async function renewAll(env, trigger = "manual", onlyAccount = null) {
  const cfg = config(env);
  const list = accounts(env);
  if (list.length === 0) {
    return { ok: false, at: new Date().toISOString(), trigger, error: "INSTABOX_API_KEY is not set" };
  }
  const results = [];
  for (const account of list) {
    if (onlyAccount && account.n !== onlyAccount) continue;
    const entry = { account: account.n, key: mask(account.key), machines: [] };
    const listed = await listMachines(cfg, account);
    if (!listed.ok) {
      entry.error = listed.error;
      results.push(entry);
      continue;
    }
    const selected = pickMachines(listed.machines, account.machine);
    if (selected.length === 0) {
      entry.note = listed.machines.length
        ? `no machine matched "${account.machine}"`
        : "this key has no machines";
      results.push(entry);
      continue;
    }
    for (const machine of selected) {
      const rotation = await maybeRotate(cfg, account, machine);
      const result = await renewOne(cfg, account, machine);
      if (rotation) result.rotation = rotation;
      entry.machines.push(result);
    }
    results.push(entry);
  }
  const failed = results.some((a) => a.error || a.machines.some((m) => m.error));
  return { ok: !failed, at: new Date().toISOString(), trigger, accounts: results };
}

async function statusAll(env, onlyAccount = null) {
  const cfg = config(env);
  const list = accounts(env);
  if (list.length === 0) {
    return { ok: false, at: new Date().toISOString(), error: "INSTABOX_API_KEY is not set" };
  }
  const results = [];
  for (const account of list) {
    if (onlyAccount && account.n !== onlyAccount) continue;
    const entry = { account: account.n, key: mask(account.key), machines: [] };
    const listed = await listMachines(cfg, account);
    if (!listed.ok) {
      entry.error = listed.error;
      results.push(entry);
      continue;
    }
    const selected = pickMachines(listed.machines, account.machine);
    if (selected.length === 0) {
      entry.note = listed.machines.length ? `no machine matched "${account.machine}"` : "this key has no machines";
      results.push(entry);
      continue;
    }
    entry.machines = selected.map((m) => ({
      name: m.name || m.id,
      id: m.id,
      state: m.state ?? "unknown",
      autoSuspendAfterSeconds: m.autoSuspendAfterSeconds ?? null,
      maxRunMinutes: m.maxRunMinutes ?? null,
    }));
    results.push(entry);
  }
  return { ok: true, at: new Date().toISOString(), accounts: results };
}

async function releaseAll(env, onlyAccount = null) {
  const cfg = config(env);
  const list = accounts(env);
  const results = [];
  for (const account of list) {
    if (onlyAccount && account.n !== onlyAccount) continue;
    const entry = { account: account.n, key: mask(account.key), machines: [] };
    const listed = await listMachines(cfg, account);
    if (!listed.ok) {
      entry.error = listed.error;
      results.push(entry);
      continue;
    }
    for (const machine of pickMachines(listed.machines, account.machine)) {
      const r = await api(
        cfg,
        account,
        "DELETE",
        `/v1/machines/${encodeURIComponent(machine.id)}/activity-leases/${encodeURIComponent(cfg.lease)}`,
      );
      entry.machines.push({
        name: machine.name || machine.id,
        released: r.ok || r.status === 404,
        ...(r.ok || r.status === 404 ? {} : { error: describe(r) }),
      });
    }
    results.push(entry);
  }
  return { ok: true, at: new Date().toISOString(), accounts: results };
}

function mask(key) {
  return key.length <= 10 ? key : `${key.slice(0, 8)}...${key.slice(-4)}`;
}

function toText(summary) {
  const lines = [`${summary.at} ${summary.trigger ?? ""}`.trim()];
  for (const a of summary.accounts || []) {
    lines.push(`account ${a.account} (${a.key})`);
    if (a.error) {
      lines.push(`  ERROR ${a.error}`);
      continue;
    }
    if (a.note) lines.push(`  ${a.note}`);
    for (const m of a.machines || []) {
      const rotation = m.rotation?.rotated ? ` (run timer reset, down ${m.rotation.downtimeSeconds}s)` : "";
      if (m.error) lines.push(`  ${m.name}: FAILED ${m.error}`);
      else if (m.skipped) lines.push(`  ${m.name}: skipped (${m.skipped})`);
      else if (m.state) lines.push(`  ${m.name}: ${m.state}${m.autoSuspendAfterSeconds == null ? "" : ` (idle pause ${m.autoSuspendAfterSeconds}s)`}`);
      else lines.push(`  ${m.name}: ${m.released ? "released" : "renewed"}${m.expiresAt ? ` until ${m.expiresAt}` : ""}${rotation}`);
    }
  }
  if (summary.error) lines.push(`error: ${summary.error}`);
  return lines.join("\n");
}

// ---------------------------------------------------------------- KV log ----
async function appendLog(env, summary, cfg) {
  if (!env.LOG || cfg.logMode === "off") return;
  try {
    const now = new Date();
    const previous = await env.LOG.get("log", "json").catch(() => null);
    const entries = Array.isArray(previous) ? previous : [];
    const last = entries[entries.length - 1];
    const sameHour =
      last &&
      new Date(last.at).toISOString().slice(0, 13) === now.toISOString().slice(0, 13) &&
      last.ok &&
      summary.ok;
    if (cfg.logMode !== "every" && sameHour) {
      last.at = summary.at;
      last.count = (last.count || 1) + 1;
    } else {
      entries.push({
        at: summary.at,
        ok: summary.ok,
        trigger: summary.trigger,
        count: 1,
        text: toText(summary),
      });
    }
    while (entries.length > 48) entries.shift();
    await env.LOG.put("log", JSON.stringify(entries));
  } catch {
    /* logging must never break renewals */
  }
}

// ------------------------------------------------------------------ routes ----
export default {
  async scheduled(_event, env, ctx) {
    const cfg = config(env);
    const summary = await renewAll(env, "cron");
    ctx.waitUntil(appendLog(env, summary, cfg));
  },

  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    const token = url.searchParams.get("token");
    const cfg = config(env);

    if (env.TOKEN && token !== env.TOKEN) {
      return text("401 wrong token", 401);
    }
    const wantedAccount = Number.parseInt(url.searchParams.get("account") || "", 10);
    const onlyAccount = Number.isFinite(wantedAccount) ? wantedAccount : null;
    const format = url.searchParams.get("format") === "text" ? "text" : "json";

    try {
      if (path === "/" || path === "/renew") {
        const summary = await renewAll(env, "manual", onlyAccount);
        if (!env.TOKEN) summary.warning = "TOKEN is not set: anyone with this URL can renew or release leases";
        await appendLog(env, summary, cfg);
        return format === "text" ? text(toText(summary)) : json(summary);
      }

      if (path === "/status") {
        const summary = await statusAll(env, onlyAccount);
        return format === "text" ? text(toText(summary)) : json(summary);
      }

      if (path === "/accounts") {
        const list = accounts(env).map((a) => ({
          account: a.n,
          key: mask(a.key),
          machines: a.machine || "all",
        }));
        if (format === "text") {
          return text(list.map((a) => `#${a.account}  ${a.key}  machines=${a.machines}`).join("\n") || "no accounts");
        }
        return json({ accounts: list });
      }

      if (path === "/release") {
        const summary = await releaseAll(env, onlyAccount);
        return format === "text" ? text(toText(summary)) : json(summary);
      }

      if (path === "/log") {
        if (!env.LOG) {
          return text("No KV namespace bound as LOG, so there is no history.", 404);
        }
        const entries = (await env.LOG.get("log", "json")) || [];
        if (format === "text") {
          return text(entries.map((e) => e.text).join("\n") || "empty");
        }
        return json({ entries });
      }

      if (path === "/health") return json({ ok: true });
      return text("not found. Try / /status /accounts /release /log", 404);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return format === "text" ? text(`error: ${message}`, 500) : json({ ok: false, error: message }, 500);
    }
  },
};
