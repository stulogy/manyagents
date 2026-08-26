// ma-relay — a dumb pipe between the ManyAgents app on a Mac and the
// ManyAgents phone client. Nothing here understands tabs, transcripts, or
// prompts; it pairs two websockets by room and forwards frames between
// them. That is deliberate: every piece of intelligence StuBuddy put in
// this path (a job queue, an LLM deciding what to relay) is a piece that
// could be wrong, slow, or down.
//
// Two roles connect to the same room:
//
//   mac    — ManyAgents itself, dialling OUT so there's no port to open
//            and no NAT to traverse. One per room; a second replaces the
//            first (the Mac restarted, the old socket is a ghost).
//   phone  — one or more clients. All of them see everything the mac
//            sends; anything they send goes to the mac.
//
// Frames are opaque. The apps encrypt with the pairing key before they
// get here, so this server routes ciphertext it cannot read — transcripts
// carry client source code and have no business being readable in transit.
// The only fields we look at are on the query string.
//
// Wire protocol (all JSON, one object per websocket message):
//   { t: 'hello',  role, room }              server → client on connect
//   { t: 'peer',   role, present: bool }     server → client on peer change
//   { t: 'env',    from, seq, data }         either direction, `data` is
//                                            the encrypted payload
//   { t: 'ping' } / { t: 'pong' }            keepalive, 30s
//
// Run it:  RELAY_TOKEN=$(openssl rand -hex 32) node relay.js
// Or mount attachMaRelay(server, { token }) into an app you already run.

import { WebSocketServer } from 'ws';

const PATH = '/ma/v1/socket';
const PING_MS = 30_000;
// A room is one Mac. Rooms are created on demand and dropped when empty,
// so there's no state to administer and nothing to clean up on deploy.
const rooms = new Map(); // roomId → { mac: ws|null, phones: Set<ws> }

function room(id) {
  if (!rooms.has(id)) rooms.set(id, { mac: null, phones: new Set() });
  return rooms.get(id);
}

function send(ws, obj) {
  if (ws && ws.readyState === ws.OPEN) {
    try { ws.send(JSON.stringify(obj)); } catch (_) {}
  }
}

/// Tell everyone in `r` whether their counterpart is currently connected.
/// The phone uses this to show "Mac offline" instead of spinning on a
/// request that can never be answered.
function announcePresence(r) {
  const macUp = !!(r.mac && r.mac.readyState === r.mac.OPEN);
  for (const p of r.phones) send(p, { t: 'peer', role: 'mac', present: macUp });
  send(r.mac, { t: 'peer', role: 'phone', present: r.phones.size > 0 });
}

export function attachMaRelay(server, { token }) {
  const wss = new WebSocketServer({ noServer: true });

  server.on('upgrade', (req, socket, head) => {
    let url;
    try { url = new URL(req.url, 'http://localhost'); } catch { return socket.destroy(); }
    if (url.pathname !== PATH) return;   // some other upgrade; not ours

    const provided = url.searchParams.get('key')
      || (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
    const roomId = url.searchParams.get('room');
    const role = url.searchParams.get('role');

    if (!token || provided !== token
        || !roomId || !/^[A-Za-z0-9._-]{8,128}$/.test(roomId)
        || (role !== 'mac' && role !== 'phone')) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      return socket.destroy();
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.maRoom = roomId;
      ws.maRole = role;
      wss.emit('connection', ws, req);
    });
  });

  wss.on('connection', (ws) => {
    const r = room(ws.maRoom);

    if (ws.maRole === 'mac') {
      // Last writer wins: a reconnecting Mac should not be locked out by
      // its own half-dead socket from a sleep/wake or a crash.
      if (r.mac && r.mac !== ws) { try { r.mac.close(4000, 'replaced'); } catch (_) {} }
      r.mac = ws;
    } else {
      r.phones.add(ws);
    }

    send(ws, { t: 'hello', role: ws.maRole, room: ws.maRoom });
    announcePresence(r);

    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });

    ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw.toString()); } catch { return; }
      if (msg.t === 'ping') return send(ws, { t: 'pong' });
      if (msg.t !== 'env') return;                 // nothing else crosses
      const envelope = { t: 'env', from: ws.maRole, seq: msg.seq, data: msg.data };
      if (ws.maRole === 'phone') {
        send(r.mac, envelope);
      } else {
        for (const p of r.phones) send(p, envelope);
      }
    });

    const bye = () => {
      if (ws.maRole === 'mac') {
        if (r.mac === ws) r.mac = null;
      } else {
        r.phones.delete(ws);
      }
      if (!r.mac && r.phones.size === 0) rooms.delete(ws.maRoom);
      else announcePresence(r);
    };
    ws.on('close', bye);
    ws.on('error', bye);
  });

  // Drop sockets that stopped answering. A phone that walked out of
  // coverage leaves a socket that looks open for a long time otherwise,
  // and the Mac would keep reporting a listener that isn't there.
  const sweeper = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.isAlive === false) { try { ws.terminate(); } catch (_) {} continue; }
      ws.isAlive = false;
      try { ws.ping(); } catch (_) {}
    }
  }, PING_MS);
  sweeper.unref?.();

  console.log(`[ma-relay] websocket relay mounted at ${PATH}`);
  return wss;
}

/// Small read-only view for a health check / debugging: which rooms exist
/// and who's in them. No frame contents, which we couldn't read anyway.
export function maRelayStatus() {
  return [...rooms.entries()].map(([id, r]) => ({
    room: id,
    mac: !!(r.mac && r.mac.readyState === r.mac.OPEN),
    phones: r.phones.size,
  }));
}


// ── Standalone server ─────────────────────────────────────────────────
// Deployed on its own this is the whole service: one HTTP endpoint for a
// health check, and the websocket upgrade the relay handles.
if (import.meta.url === `file://${process.argv[1]}`) {
  const { createServer } = await import('http');
  const token = process.env.RELAY_TOKEN;
  if (!token) {
    console.error('Set RELAY_TOKEN. Generate one with: openssl rand -hex 32');
    process.exit(1);
  }
  const port = process.env.PORT || 8787;
  const server = createServer((req, res) => {
    if (req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: true, rooms: maRelayStatus() }));
      return;
    }
    res.writeHead(404); res.end();
  });
  attachMaRelay(server, { token });
  server.listen(port, () => console.log(`ma-relay listening on :${port}`));
}
