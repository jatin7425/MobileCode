# Connecting to a GitHub Codespace

A Codespace is an appealing target for this app — a dev machine you don't have
to own or pay for around the clock. Getting to one from a phone takes a
detour, and this document explains why, and what we do about it.

## The problem

**A Codespace has no public SSH endpoint.** `gh codespace ssh` does not dial a
host and port; it establishes a tunnel through GitHub's Dev Tunnels service
and runs SSH over it via a `ProxyCommand`, the same infrastructure that backs
port forwarding. There is nothing for `dartssh2` to connect to.

Two ways past that:

1. **Reimplement the Dev Tunnels client.** Behaves exactly like `gh`, needs no
   setup inside the Codespace. But Microsoft ships SDKs for C#, JavaScript,
   and Go — not Dart — so this means building a client against a protocol with
   no Dart implementation and no stable public specification, which then
   breaks whenever they change it.

2. **Run SSH over a forwarded port.** A Codespace can forward a port as an
   HTTPS URL, and those URLs accept a WebSocket upgrade — that is how VS Code
   itself talks to a Codespace. SSH only needs an ordered, reliable byte
   stream, so it runs inside a WebSocket perfectly well.

We do the second. It costs a one-time setup step inside each Codespace and
buys a transport built entirely on documented, stable behaviour.

## How it fits together

```
  phone                          GitHub tunnel            Codespace
┌──────────────────┐            ┌────────────┐   ┌────────────────────────┐
│ dartssh2         │            │            │   │ websocat  :2222        │
│   └ WebSocket…   │═══ wss ═══▶│ forwarded  │══▶│    └ tcp 127.0.0.1:2223│
│      SshSocket   │            │ port :2222 │   │         └ sshd         │
└──────────────────┘            └────────────┘   └────────────────────────┘
```

`WebSocketSshSocket` implements dartssh2's `SSHSocket` interface over a
WebSocket. Everything above it — authentication, host key pinning, tmux
session handling, the terminal — is unchanged, because that interface is the
only thing the SSH layer knows about its transport.

sshd listens on **loopback only**. The bridge is the sole way in, so the
daemon is never directly exposed even though the forwarded port is public.

## Setup

Inside the Codespace, once per Codespace:

```sh
./tools/codespace-bridge.sh "$(cat ~/.ssh/id_ed25519.pub)"
```

Pass the **public** half of the key pair whose private half you added to the
app. The script installs `openssh-server` and `websocat`, authorises your key,
starts sshd on loopback, starts the bridge, and sets the forwarded port to
public. It prints the URL to give the app.

## Security

A public forwarded port is reachable by **anyone who learns the URL** — the
hostname is derived from the Codespace name, not a secret. What protects the
machine is SSH itself:

- The bridge config sets `PasswordAuthentication no`. Keys only. A guessable
  password must never be an option on a port with no other gate.
- sshd binds loopback, so nothing but the bridge can reach it.
- Host key pinning applies exactly as for any other host: the app pins on
  first connect and refuses a changed key with no click-through.

Note that a rebuilt Codespace regenerates its host key, which will correctly
trip the mismatch warning. Clear the pin in settings when you know that is
why.

## Status

The transport is proven: `test/ssh_over_websocket_test.dart` runs a real SSH
session — authentication and two sequential commands — over
`WebSocketSshSocket` against a real `sshd`, through a WebSocket bridge that
reproduces this topology.

What is **not** yet verified is the leg through GitHub's tunnel: whether their
proxy passes a WebSocket upgrade through to a forwarded port cleanly enough
for SSH, at what latency, and with what idle timeouts. VS Code's own use of
WebSockets over forwarded ports is good evidence, but evidence is not a test.
Trying `tools/codespace-bridge.sh` against a live Codespace is the next step.
