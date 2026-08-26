# ManyAgents relay

A dumb pipe between the ManyAgents Mac app and the iOS companion. It pairs
two websockets by room and forwards frames between them. That's the whole
service — about 150 lines.

It is deliberately ignorant. It doesn't know what a tab is, it can't read
what it carries (the apps seal every payload with a pairing key it never
sees), and it stores nothing. If it goes down, you lose remote access to
your agents and nothing else.

## Why a relay at all

The Mac dials **out** to it. That means no port forwarding, no NAT
traversal, no dynamic DNS, and it works from cellular — which is the point,
since the moment you actually want to check on an agent is when you're not
at your desk.

## Run it

```sh
npm install
RELAY_TOKEN=$(openssl rand -hex 32) npm start
```

Deploy that anywhere that speaks websockets — Railway, Fly, Render, a VPS,
a Raspberry Pi on your own network. Set `RELAY_TOKEN` in the environment
and put the same value in ManyAgents → Settings → Phone, along with the
URL (`wss://…` in production; `ws://…` only for localhost).

`GET /health` reports which rooms are occupied, and nothing about what's
in them.

## What the token does, and doesn't

`RELAY_TOKEN` is the door: without it you can't open a socket. It is *not*
what protects your transcripts. Those are encrypted end to end with the
pairing key that only your Mac and your phone hold, so a relay operator —
including you — cannot read what passes through.

Rotate the pairing key from ManyAgents → Settings → Phone → "Generate a
new code" to revoke a lost phone.
