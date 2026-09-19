#!/usr/bin/env node
// Tests for capabilities/agents.dsh/gate.mjs: runs the gate against a fake
// JWKS endpoint and a fake harness, all on loopback. `node tests/gate.test.mjs`.
import http from "node:http";
import net from "node:net";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const GATE = path.join(here, "..", "capabilities", "agents.dsh", "gate.mjs");
let pass = 0, fail = 0;
const ok = (name, cond) => { if (cond) { pass++; console.log("  ok   " + name); } else { fail++; console.log("  FAIL " + name); } };
const b64url = (b) => Buffer.from(b).toString("base64").replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
const listen = (srv) => new Promise((r) => srv.listen(0, "127.0.0.1", () => r(srv.address().port)));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- fixtures ---------------------------------------------------------------
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "aw-gate-"));
const harnessSecret = crypto.randomBytes(32);
fs.writeFileSync(path.join(tmp, "creds.yaml"), `version: 1\nrecords:\n  client-connection/browser-session:\n    kind: grant\n    payload:\n      version: 1\n      secret: ${b64url(harnessSecret)}\n`);

const rsa = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const otherRsa = crypto.generateKeyPairSync("rsa", { modulusLength: 2048 });
const KID = "kid-1";
const jwksServer = http.createServer((req, res) => {
  const jwk = rsa.publicKey.export({ format: "jwk" });
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ keys: [{ ...jwk, kid: KID, alg: "RS256", use: "sig" }] }));
});
const jwksPort = await listen(jwksServer);

const ed = crypto.generateKeyPairSync("ed25519");
fs.writeFileSync(path.join(tmp, "control-pubkey.json"), JSON.stringify({ kid: "ck-test", alg: "Ed25519", publicKey: ed.publicKey.export({ format: "der", type: "spki" }).toString("base64") }));

// Fake harness: echoes the headers it saw as JSON; upgrades echo one frame's raw bytes.
const seen = [];
const upstream = http.createServer((req, res) => {
  seen.push({ url: req.url, headers: req.headers });
  res.setHeader("content-type", "application/json");
  res.end(JSON.stringify({ url: req.url, cookie: req.headers.cookie || "", host: req.headers.host }));
});
upstream.on("upgrade", (req, socket) => {
  seen.push({ url: req.url, headers: req.headers, upgrade: true });
  socket.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n");
  socket.on("data", (d) => socket.write("echo:" + d.toString()));
});
const upPort = await listen(upstream);

const TEAM = "team.example.test";
const AUD = "aud-node-ui";
function token({ key = rsa.privateKey, kid = KID, aud = AUD, iss = `https://${TEAM}`, exp = Math.floor(Date.now() / 1000) + 300, email = "op@example.com" } = {}) {
  const h = b64url(JSON.stringify({ alg: "RS256", kid, typ: "JWT" }));
  const p = b64url(JSON.stringify({ iss, aud: [aud], exp, iat: Math.floor(Date.now() / 1000), email, sub: "sub-1" }));
  const sig = crypto.sign("RSA-SHA256", Buffer.from(h + "." + p), key);
  return `${h}.${p}.${b64url(sig)}`;
}
function tenantSession({ key = ed.privateKey, host = "kitchen.example.test", exp = Math.floor(Date.now() / 1000) + 300 } = {}) {
  const payload = b64url(JSON.stringify({ sub: "tenant-1", host, exp }));
  const sig = crypto.sign(null, Buffer.from("AW-SESSION-V1\n" + payload), key);
  return `v1.${payload}.${b64url(sig)}`;
}

// --- start the gate ---------------------------------------------------------
const gatePort = 30000 + Math.floor(Math.random() * 20000);
const gate = spawn(process.execPath, [GATE], {
  env: {
    ...process.env, DSH_PORT: String(gatePort), AW_UPSTREAM: `127.0.0.1:${upPort}`, AW_GATE_BIND: "127.0.0.1",
    AW_ACCESS_TEAM_DOMAIN: TEAM, AW_ACCESS_AUD: AUD, AW_ACCESS_CERTS_URL: `http://127.0.0.1:${jwksPort}/certs`,
    AW_CONTROL_PUBKEY_FILE: path.join(tmp, "control-pubkey.json"), AW_CREDENTIALS_FILE: path.join(tmp, "creds.yaml"), HOME: tmp,
  },
  stdio: ["ignore", "pipe", "inherit"],
});
let gateLog = "";
gate.stdout.on("data", (d) => { gateLog += d.toString(); });
for (let i = 0; i < 50 && !gateLog.includes("gate listening"); i++) await sleep(100);
ok("gate starts and reports both credential classes", gateLog.includes('"access":true') && gateLog.includes('"tenantSessions":true'));

const HOST = "kitchen.example.test";
// http.request, not fetch: undici refuses a caller-set Host header, and the
// Host is exactly what the gate must see (it is the harness cookie's authority).
function rawGet(port, pathname, headers = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path: pathname, method: "GET", headers: { host: HOST, ...headers } }, (res) => {
      let text = ""; res.on("data", (d) => { text += d; }); res.on("end", () => resolve({ status: res.statusCode, text }));
    });
    req.on("error", reject); req.end();
  });
}
const get = (pathname, headers = {}) => rawGet(gatePort, pathname, headers);
const expectedCookieName = "dsh-auth-" + b64url(crypto.createHash("sha256").update(HOST).digest());
function cookieValid(cookieHeader) {
  const m = new RegExp(expectedCookieName + "=v1\\.([A-Za-z0-9_-]+)\\.([A-Za-z0-9_-]+)").exec(cookieHeader || "");
  if (!m) return false;
  const sig = crypto.createHmac("sha256", harnessSecret).update(m[1]).digest();
  const payload = JSON.parse(Buffer.from(m[1].replaceAll("-", "+").replaceAll("_", "/"), "base64").toString());
  return b64url(sig) === m[2] && payload.authority === HOST && payload.expiresAt > payload.issuedAt;
}

// --- cases -----------------------------------------------------------------------
let r = await get("/_aw/health");
ok("health needs no auth", r.status === 204);

r = await get("/");
ok("no credential -> 401", r.status === 401 && r.text.includes("Access required"));
ok("nothing reached the harness", seen.length === 0);

r = await get("/", { "cf-access-jwt-assertion": token() });
ok("valid Access JWT -> proxied", r.status === 200 && JSON.parse(r.text).host === HOST);
ok("harness got a freshly minted, valid session cookie", seen.length === 1 && cookieValid(seen[0].headers.cookie));

r = await get("/api", { "cf-access-jwt-assertion": token(), cookie: "theme=dark; dsh-auth-stale=v1.x.y" });
ok("stale harness cookie stripped, other cookies kept", seen.length === 2 && seen[1].headers.cookie.includes("theme=dark") && !seen[1].headers.cookie.includes("dsh-auth-stale") && cookieValid(seen[1].headers.cookie));

r = await get("/", { cookie: "CF_Authorization=" + token() });
ok("JWT accepted from the CF_Authorization cookie", r.status === 200);

r = await get("/", { "cf-access-jwt-assertion": token({ aud: "other-app" }) });
ok("JWT for another Access application -> 401", r.status === 401);
r = await get("/", { "cf-access-jwt-assertion": token({ key: otherRsa.privateKey }) });
ok("JWT signed by a foreign key -> 401", r.status === 401);
r = await get("/", { "cf-access-jwt-assertion": token({ exp: Math.floor(Date.now() / 1000) - 10 }) });
ok("expired JWT -> 401", r.status === 401);
r = await get("/", { "cf-access-jwt-assertion": token({ iss: "https://evil.example.test" }) });
ok("wrong issuer -> 401", r.status === 401);
r = await get("/", { "cf-access-jwt-assertion": "not.a.jwt" });
ok("garbage token -> 401", r.status === 401);

r = await get("/", { cookie: "aw-session=" + tenantSession() });
ok("control-plane tenant session -> proxied", r.status === 200);
{
  // The portal handoff: ?aw_session= becomes an HttpOnly cookie and the URL is cleaned.
  const tok = tenantSession();
  const hand = await new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port: gatePort, path: "/chat?x=1&aw_session=" + encodeURIComponent(tok), method: "GET", headers: { host: HOST } }, (res) => { res.resume(); res.on("end", () => resolve({ status: res.statusCode, headers: res.headers })); });
    req.on("error", reject); req.end();
  });
  ok("tenant handoff sets the session cookie and redirects without the token", hand.status === 302 && String(hand.headers["set-cookie"]).includes("aw-session=" + tok) && String(hand.headers["set-cookie"]).includes("HttpOnly") && hand.headers.location === "/chat?x=1");
  const bad = await get("/?aw_session=v1.garbage.sig");
  ok("a bad handoff token is refused", bad.status === 401);
}
r = await get("/", { cookie: "aw-session=" + tenantSession({ host: "other.example.test" }) });
ok("tenant session for another host -> 401", r.status === 401);
r = await get("/", { cookie: "aw-session=" + tenantSession({ exp: Math.floor(Date.now() / 1000) - 5 }) });
ok("expired tenant session -> 401", r.status === 401);
const otherEd = crypto.generateKeyPairSync("ed25519");
r = await get("/", { cookie: "aw-session=" + tenantSession({ key: otherEd.privateKey }) });
ok("tenant session signed by an unpinned key -> 401", r.status === 401);

// WebSocket upgrade: authenticated goes through with the minted cookie; anonymous is refused.
async function upgrade(headers) {
  return new Promise((resolve) => {
    const s = net.connect(gatePort, "127.0.0.1", () => {
      let raw = `GET /ws HTTP/1.1\r\nHost: ${HOST}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n`;
      for (const [k, v] of Object.entries(headers)) raw += `${k}: ${v}\r\n`;
      s.write(raw + "\r\n");
    });
    let buf = "";
    s.on("data", (d) => { buf += d.toString(); if (buf.includes("101") && !buf.includes("echo:")) s.write("ping"); if (buf.includes("echo:ping") || buf.includes("401")) { s.destroy(); resolve(buf); } });
    s.on("error", () => resolve(buf)); s.on("close", () => resolve(buf));
    setTimeout(() => { s.destroy(); resolve(buf); }, 3000);
  });
}
let ws = await upgrade({ "cf-access-jwt-assertion": token() });
ok("authenticated WebSocket upgrade is proxied end to end", ws.includes("101") && ws.includes("echo:ping"));
ok("upgrade carried the minted harness cookie", cookieValid(seen.at(-1)?.headers.cookie));
ws = await upgrade({});
ok("anonymous WebSocket upgrade -> 401", ws.includes("401"));

// Unconfigured gate fails closed even with a valid token.
gate.kill();
const bare = spawn(process.execPath, [GATE], { env: { ...process.env, DSH_PORT: String(gatePort + 1), AW_UPSTREAM: `127.0.0.1:${upPort}`, AW_GATE_BIND: "127.0.0.1", HOME: tmp }, stdio: ["ignore", "pipe", "inherit"] });
let bareLog = ""; bare.stdout.on("data", (d) => { bareLog += d.toString(); });
for (let i = 0; i < 50 && !bareLog.includes("gate listening"); i++) await sleep(100);
const bareRes = await rawGet(gatePort + 1, "/", { "cf-access-jwt-assertion": token() });
ok("unconfigured gate refuses everything (fail closed)", bareRes.status === 401 && bareRes.text.includes("not configured"));
bare.kill();

jwksServer.close(); upstream.close();
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`\ngate: passed ${pass}  failed ${fail}`);
process.exit(fail ? 1 : 0);
