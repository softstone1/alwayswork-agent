#!/usr/bin/env node
// alwayswork gate — node-side session mint (SYSTEM_SPEC §10 option B).
//
// Sits in front of the harness INSIDE the workload container. The harness
// only trusts its own signed browser-session cookie, and a request that
// arrives through the node's Cloudflare Tunnel has been authenticated by
// Cloudflare Access at the edge but carries no such cookie. The gate closes
// that gap on the node, so no per-node edge Worker is needed:
//
//   browser -> Access -> tunnel -> [gate :PORT on the container interface]
//           -> verify Cf-Access-Jwt-Assertion against the team's JWKS
//           -> mint dsh-auth-<sha256(authority)> from the harness's own secret
//           -> proxy (HTTP + WebSocket) to the harness on 127.0.0.1:PORT
//
// A second credential class is accepted for tenants (§12.6): an `aw-session`
// cookie signed by the control plane's Ed25519 key, which the node already
// pins at enrolment. Nothing else is accepted: no header, no cookie -> 401.
//
// Zero dependencies (node:crypto verifies RS256 and Ed25519). Configuration
// by environment:
//   DSH_PORT                 public port on the container interface (default 3080)
//   AW_UPSTREAM              harness address (default 127.0.0.1:DSH_PORT)
//   AW_GATE_BIND             listen address (default: the container's interface)
//   AW_ACCESS_TEAM_DOMAIN    <team>.cloudflareaccess.com  (Access path on)
//   AW_ACCESS_AUD            the node-UI Access application's AUD (required with the team domain)
//   AW_ACCESS_CERTS_URL      JWKS override, tests only
//   AW_CONTROL_PUBKEY_FILE   pinned control key JSON {kid, alg, publicKey} (aw-session path on)
//   AW_CREDENTIALS_FILE      harness credentials (default $HOME/.dsh/.credentials.yaml)
//   AW_SESSION_HOURS         minted cookie lifetime (default 12; the harness caps it)
import http from "node:http";
import net from "node:net";
import os from "node:os";
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const env = process.env;
const PORT = Number(env.DSH_PORT || 3080);
const UPSTREAM = (() => {
  const [h, p] = String(env.AW_UPSTREAM || `127.0.0.1:${PORT}`).split(":");
  return { host: h, port: Number(p || PORT) };
})();
const TEAM = (env.AW_ACCESS_TEAM_DOMAIN || "").replace(/^https?:\/\//, "").replace(/\/+$/, "");
const AUD = env.AW_ACCESS_AUD || "";
const CERTS_URL = env.AW_ACCESS_CERTS_URL || (TEAM ? `https://${TEAM}/cdn-cgi/access/certs` : "");
const ISSUER = TEAM ? `https://${TEAM}` : "";
const CONTROL_PUBKEY_FILE = env.AW_CONTROL_PUBKEY_FILE || "";
const CREDENTIALS_FILE = env.AW_CREDENTIALS_FILE || path.join(env.HOME || "/home/dsh", ".dsh", ".credentials.yaml");
const SESSION_MS = Math.max(1, Number(env.AW_SESSION_HOURS || 12)) * 3600_000;

const log = (o) => process.stdout.write(JSON.stringify({ t: new Date().toISOString(), ...o }) + "\n");
const b64url = (buf) => Buffer.from(buf).toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
const fromB64url = (s) => Buffer.from(String(s).replaceAll("-", "+").replaceAll("_", "/"), "base64");

// ---- the harness's own signing secret -------------------------------------
// ~/.dsh/.credentials.yaml, record client-connection/browser-session. Reread
// when the file changes (the harness creates it on first boot).
let secretCache = { mtime: -1, secret: null };
function harnessSecret() {
  try {
    const st = fs.statSync(CREDENTIALS_FILE);
    if (st.mtimeMs === secretCache.mtime) return secretCache.secret;
    const text = fs.readFileSync(CREDENTIALS_FILE, "utf8");
    const idx = text.indexOf("client-connection/browser-session:");
    const m = idx >= 0 ? /^\s+secret:\s*([A-Za-z0-9_-]+)\s*$/m.exec(text.slice(idx)) : null;
    const secret = m ? fromB64url(m[1]) : null;
    secretCache = { mtime: st.mtimeMs, secret: secret && secret.length === 32 ? secret : null };
    return secretCache.secret;
  } catch {
    return null;
  }
}

function mintHarnessCookie(authority) {
  const secret = harnessSecret();
  if (!secret) return null;
  const name = "dsh-auth-" + b64url(crypto.createHash("sha256").update(authority).digest());
  const now = Date.now();
  const body = b64url(Buffer.from(JSON.stringify({ version: 1, authority, issuedAt: now, expiresAt: now + SESSION_MS })));
  const sig = crypto.createHmac("sha256", secret).update(body).digest();
  return `${name}=v1.${body}.${b64url(sig)}`;
}

// ---- Cloudflare Access JWT (RS256, team JWKS) ------------------------------
let jwks = { at: 0, keys: new Map() };
async function fetchJwks(force) {
  if (!CERTS_URL) return jwks.keys;
  if (!force && Date.now() - jwks.at < 600_000 && jwks.keys.size > 0) return jwks.keys;
  const res = await fetch(CERTS_URL, { signal: AbortSignal.timeout(5000) });
  if (!res.ok) throw new Error(`jwks ${res.status}`);
  const body = await res.json();
  const keys = new Map();
  for (const k of body.keys || []) {
    if (k.kty !== "RSA" || !k.kid) continue;
    try { keys.set(k.kid, crypto.createPublicKey({ key: k, format: "jwk" })); } catch { /* skip */ }
  }
  jwks = { at: Date.now(), keys };
  return keys;
}

function parseJwt(token) {
  const parts = String(token).split(".");
  if (parts.length !== 3) return null;
  try {
    return {
      header: JSON.parse(fromB64url(parts[0]).toString("utf8")),
      payload: JSON.parse(fromB64url(parts[1]).toString("utf8")),
      signed: Buffer.from(parts[0] + "." + parts[1]),
      sig: fromB64url(parts[2]),
    };
  } catch {
    return null;
  }
}

async function verifyAccess(token) {
  if (!TEAM || !AUD) return null;
  const jwt = parseJwt(token);
  if (!jwt || jwt.header.alg !== "RS256" || !jwt.header.kid) return null;
  let key = (await fetchJwks(false)).get(jwt.header.kid);
  if (!key) key = (await fetchJwks(true)).get(jwt.header.kid);
  if (!key) return null;
  if (!crypto.verify("RSA-SHA256", jwt.signed, key, jwt.sig)) return null;
  const p = jwt.payload;
  const now = Math.floor(Date.now() / 1000);
  if (p.iss !== ISSUER) return null;
  const auds = Array.isArray(p.aud) ? p.aud : [p.aud];
  if (!auds.includes(AUD)) return null;
  if (typeof p.exp !== "number" || p.exp <= now) return null;
  if (typeof p.nbf === "number" && p.nbf > now + 60) return null;
  return { kind: "access", subject: p.email || p.sub || "access-user" };
}

// ---- control-plane tenant session (Ed25519, pinned key) --------------------
let controlKey = { mtime: -1, key: null };
function pinnedControlKey() {
  if (!CONTROL_PUBKEY_FILE) return null;
  try {
    const st = fs.statSync(CONTROL_PUBKEY_FILE);
    if (st.mtimeMs === controlKey.mtime) return controlKey.key;
    const j = JSON.parse(fs.readFileSync(CONTROL_PUBKEY_FILE, "utf8"));
    const key = j.publicKey ? crypto.createPublicKey({ key: Buffer.from(j.publicKey, "base64"), format: "der", type: "spki" }) : null;
    controlKey = { mtime: st.mtimeMs, key };
    return key;
  } catch {
    return null;
  }
}

// aw-session=v1.<b64url payload>.<b64url sig>; sig = Ed25519("AW-SESSION-V1\n" + payload)
// payload: { sub, host, exp (unix seconds), workload? }
function verifyControlSession(value, authority) {
  const key = pinnedControlKey();
  if (!key) return null;
  const parts = String(value).split(".");
  if (parts.length !== 3 || parts[0] !== "v1") return null;
  try {
    const ok = crypto.verify(null, Buffer.from("AW-SESSION-V1\n" + parts[1]), key, fromB64url(parts[2]));
    if (!ok) return null;
    const p = JSON.parse(fromB64url(parts[1]).toString("utf8"));
    if (p.host !== authority.split(":")[0]) return null;
    if (typeof p.exp !== "number" || p.exp * 1000 <= Date.now()) return null;
    return { kind: "tenant", subject: String(p.sub || "tenant") };
  } catch {
    return null;
  }
}

// ---- request handling --------------------------------------------------------
function cookies(header) {
  const out = [];
  for (const seg of String(header || "").split(";")) {
    const s = seg.trim();
    if (!s) continue;
    const i = s.indexOf("=");
    out.push([i < 0 ? s : s.slice(0, i), i < 0 ? "" : s.slice(i + 1)]);
  }
  return out;
}

async function authenticate(req) {
  const authority = String(req.headers.host || "");
  const jar = cookies(req.headers.cookie);
  const assertion = req.headers["cf-access-jwt-assertion"] || jar.find(([n]) => n === "CF_Authorization")?.[1];
  if (assertion) {
    const who = await verifyAccess(assertion).catch(() => null);
    if (who) return { ...who, authority };
  }
  const session = jar.find(([n]) => n === "aw-session")?.[1];
  if (session) {
    const who = verifyControlSession(session, authority);
    if (who) return { ...who, authority };
  }
  return null;
}

function upstreamHeaders(req, authority) {
  const headers = { ...req.headers };
  // Keep the browser's cookies, drop any stale harness session, state ours last.
  const kept = cookies(req.headers.cookie).filter(([n]) => !n.startsWith("dsh-auth-")).map(([n, v]) => `${n}=${v}`);
  const minted = mintHarnessCookie(authority);
  if (minted) kept.push(minted);
  if (kept.length) headers.cookie = kept.join("; "); else delete headers.cookie;
  // The harness compares Origin to Host; both are the public name here, so
  // nothing to rewrite. Loopback-hop headers go; Cloudflare's stay.
  delete headers.connection;
  return headers;
}

function deny(res, status, text) {
  res.writeHead(status, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store" });
  res.end(text + "\n");
}

const notConfigured = !((TEAM && AUD) || CONTROL_PUBKEY_FILE);

const server = http.createServer(async (req, res) => {
  if (req.url === "/_aw/health") { res.writeHead(204); return res.end(); }
  if (notConfigured) return deny(res, 401, "alwayswork: node UI gate is not configured (deliver access.teamDomain + access.uiAud to this node)");
  // A tenant arrives from the portal with the control-plane session in the
  // query (the portal cannot set a cookie for this hostname). Verify it,
  // move it into an HttpOnly cookie, and redirect to the same path without it.
  const u = new URL(req.url, "http://x");
  const handoff = u.searchParams.get("aw_session");
  if (handoff !== null) {
    const authority = String(req.headers.host || "");
    const who = verifyControlSession(handoff, authority);
    if (!who) { log({ msg: "denied handoff" }); return deny(res, 401, "invalid or expired session"); }
    u.searchParams.delete("aw_session");
    res.writeHead(302, {
      "set-cookie": `aw-session=${handoff}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${12 * 3600}`,
      location: u.pathname + (u.search || ""),
      "cache-control": "no-store",
    });
    return res.end();
  }
  const who = await authenticate(req);
  if (!who) { log({ msg: "denied", path: req.url }); return deny(res, 401, "Cloudflare Access required"); }
  const headers = upstreamHeaders(req, who.authority);
  const up = http.request({ host: UPSTREAM.host, port: UPSTREAM.port, method: req.method, path: req.url, headers }, (ur) => {
    res.writeHead(ur.statusCode || 502, ur.headers);
    ur.pipe(res);
  });
  up.on("error", (e) => { log({ msg: "upstream error", err: e.message }); if (!res.headersSent) deny(res, 502, "harness unreachable"); else res.destroy(); });
  req.pipe(up);
});

server.on("upgrade", async (req, socket, head) => {
  if (notConfigured) { socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n"); return socket.destroy(); }
  const who = await authenticate(req);
  if (!who) { log({ msg: "denied upgrade", path: req.url }); socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n"); return socket.destroy(); }
  const headers = upstreamHeaders(req, who.authority);
  headers.connection = "Upgrade";
  const up = net.connect(UPSTREAM.port, UPSTREAM.host, () => {
    let raw = `${req.method} ${req.url} HTTP/1.1\r\n`;
    for (const [k, v] of Object.entries(headers)) {
      for (const one of Array.isArray(v) ? v : [v]) raw += `${k}: ${one}\r\n`;
    }
    up.write(raw + "\r\n");
    if (head && head.length) up.write(head);
    socket.pipe(up).pipe(socket);
  });
  up.on("error", () => socket.destroy());
  socket.on("error", () => up.destroy());
});

function bindAddress() {
  if (env.AW_GATE_BIND) return env.AW_GATE_BIND;
  for (const list of Object.values(os.networkInterfaces())) {
    for (const i of list || []) if (i.family === "IPv4" && !i.internal) return i.address;
  }
  return null;
}

const bind = bindAddress();
if (!bind) {
  log({ msg: "no external interface; gate idle (network none)" });
} else {
  server.listen(PORT, bind, () => log({ msg: "gate listening", bind, port: PORT, upstream: UPSTREAM, access: Boolean(TEAM && AUD), tenantSessions: Boolean(CONTROL_PUBKEY_FILE) }));
}
