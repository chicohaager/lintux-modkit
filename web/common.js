'use strict';
// Shared front-end helpers of the Lintux modules (copied into each module's web
// root at build time from lintux-modkit/web/common.js; edit it there).
//
//   api(path, {method, body})  JSON call with the ZimaOS session token; a 401 goes
//                              through POST /v1/users/refresh once
//   esc(s), $(sel), setStatus(msg, kind), describe(err), initTheme(key)
//   zfw.present() / zfw.allows(port, proto, from) / zfw.open(port, proto, name, notes, from) / zfw.close(port, proto)
//                              (+ allowsUdp/openUdp/closeUdp); from 'lan' = only the LAN range ZFW has
//                              ZFW firewall, called from the browser: same origin and
//                              the user's own token satisfy ZFW's auth and CSRF checks

const $ = (sel) => document.querySelector(sel);

function safeGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function safeSet(k, v) { try { localStorage.setItem(k, v); } catch { /* private window */ } }

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

class ApiError extends Error {
  constructor(status, code, message) { super(message); this.status = status; this.code = code; }
}

async function api(path, opts = {}, retried = false) {
  const headers = { Accept: 'application/json', ...(opts.headers || {}) };
  if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
  const token = safeGet('access_token');
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(path, { ...opts, headers, body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined });
  if (res.status === 401 && !retried && await refreshSession()) return api(path, opts, true);
  const isJson = (res.headers.get('content-type') || '').includes('application/json');
  const data = isJson ? await res.json().catch(() => ({})) : await res.text();
  if (!res.ok) throw new ApiError(res.status, (data && data.code) || 'http', (data && (data.error || data.message)) || `HTTP ${res.status}`);
  return data;
}

let refreshing = null;
function refreshSession() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    const rt = safeGet('refresh_token');
    if (!rt) return false;
    try {
      const res = await fetch('/v1/users/refresh', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ refresh_token: rt }) });
      const body = res.ok ? await res.json() : null;
      const d = body && body.data;
      if (!d || !d.access_token) return false;
      safeSet('access_token', d.access_token);
      if (d.refresh_token) safeSet('refresh_token', d.refresh_token);
      if (d.expires_at !== undefined) safeSet('expires_at', String(d.expires_at));
      return true;
    } catch {
      return false;
    } finally {
      setTimeout(() => { refreshing = null; }, 0);
    }
  })();
  return refreshing;
}

function setStatus(msg, kind) {
  const el = $('#status');
  el.textContent = msg || '';
  el.className = kind || '';
}

function describe(err) {
  if (err instanceof ApiError && err.status === 401) return 'Session expired — reload the ZimaOS page and sign in again.';
  return err.message || String(err);
}

function applyTheme(t) {
  if (t === 'light' || t === 'dark') document.documentElement.setAttribute('data-theme', t);
  else document.documentElement.removeAttribute('data-theme');
}

function initTheme(key) {
  const sel = $('#theme-select');
  const stored = safeGet(key);
  sel.value = stored === 'light' || stored === 'dark' ? stored : 'auto';
  sel.addEventListener('change', () => { safeSet(key, sel.value); applyTheme(sel.value); });
}

// Download a text as a file (client configs, certificates).
function download(name, text) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type: 'text/plain' }));
  a.download = name;
  document.body.appendChild(a);
  a.click();
  setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 0);
}

// ---------- ZFW firewall ----------
// ZFW drops incoming traffic it does not know (measured on ZimaOS 1.8.0): a VPN's
// UDP listen port needs an allow rule. Rules are saved, applied, then committed —
// only committed rules are restored at boot.
const ZFW = '/v2/zfw/api';
const zfw = {
  async present() {
    try { const r = await fetch(`${ZFW}/health`); return r.ok; } catch { return false; }
  },
  // An allow rule that lets <proto> traffic to <port> in from everywhere, or — from 'lan' —
  // from the LAN at least (source any, or the range ZFW knows as the LAN).
  matches(rule, port, proto = 'udp', from = 'any', lan = '') {
    const src = rule.source?.type || 'any';
    const fromOk = src === 'any' || (from === 'lan' && src === 'range' && lan !== '' && rule.source.value === lan);
    return rule.enabled && rule.action === 'allow' && (rule.protocol === proto || rule.protocol === 'both') && fromOk &&
      ((rule.ports?.type === 'all') || (rule.ports?.type === 'list' && (rule.ports.list || []).includes(port)) ||
       (rule.ports?.type === 'range' && rule.ports.from <= port && port <= rule.ports.to));
  },
  ruleId(port, proto) { return `mod-${proto}-${port}`.slice(0, 16); },
  async allows(port, proto = 'udp', from = 'any') {
    const rs = await api(`${ZFW}/rules`);
    if (rs.default_policy === 'allow') return true;
    return (rs.rules || []).some((r) => zfw.matches(r, port, proto, from, rs.lan || ''));
  },
  // Adds an allow rule (id mod-<proto>-<port>) unless one covers the port already. from 'lan'
  // limits it to the LAN range ZFW has (rules.json "lan"): right for a metrics port.
  async open(port, proto, name, notes, from = 'any') {
    const rs = await api(`${ZFW}/rules`);
    rs.rules = rs.rules || [];
    if (from === 'lan' && !rs.lan) throw new Error('ZFW knows no LAN range; set it in the ZFW tile');
    if (!rs.rules.some((r) => zfw.matches(r, port, proto, from, rs.lan || ''))) {
      const order = rs.rules.reduce((m, r) => Math.max(m, r.order || 0), 0) + 1;
      const id = zfw.ruleId(port, proto);
      if (rs.rules.some((r) => r.id === id)) throw new Error(`ZFW already has a rule with id ${id}; check the ZFW tile`);
      const source = from === 'lan' ? { type: 'range', value: rs.lan } : { type: 'any', value: '' };
      rs.rules.push({ id, order, enabled: true, name, action: 'allow', source,
        ports: { type: 'list', list: [port] }, protocol: proto, zone: 'host', notes });
      await api(`${ZFW}/rules`, { method: 'POST', body: rs });
    }
    // Not safe:true — ZFW's dead-man REMOVES the whole firewall after 120 s without a
    // commit (engine/zfw arm_deadman: "not a restore of the previous rules"). Should the
    // commit below fail, an unsafe apply leaves the old rules plus this allow live.
    await api(`${ZFW}/apply`, { method: 'POST', body: { safe: false } });
    await api(`${ZFW}/commit`, { method: 'POST', body: {} });
  },
  // Removes only the rule open() added for this port (id mod-<proto>-<port>); a rule the user
  // made by hand for the same port stays. Returns false when there was nothing to remove.
  async close(port, proto) {
    const rs = await api(`${ZFW}/rules`);
    const id = zfw.ruleId(port, proto);
    const before = (rs.rules || []).length;
    rs.rules = (rs.rules || []).filter((r) => r.id !== id);
    if (rs.rules.length === before) return false;
    await api(`${ZFW}/rules`, { method: 'POST', body: rs });
    await api(`${ZFW}/apply`, { method: 'POST', body: { safe: false } });
    await api(`${ZFW}/commit`, { method: 'POST', body: {} });
    return true;
  },
  // The UDP calls the WireGuard and Nebula tiles use (rule ids mod-udp-<port> as before).
  allowsUdp(port) { return zfw.allows(port, 'udp'); },
  openUdp(port, name, notes) { return zfw.open(port, 'udp', name, notes); },
  closeUdp(port) { return zfw.close(port, 'udp'); },
};
