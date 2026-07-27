# MobileCode — Architecture

Code from your phone. MobileCode is a Flutter app (iOS + Android) that connects
over SSH to machines you already own — a dev box, a VPS, a work laptop — and
drives the coding CLI agents installed there (`claude`,
`codex`, `gemini`, and friends) through a terminal built for a small screen.

## 1. Shape of the system

```
┌──────────────────────────┐            ┌───────────────────────────────┐
│  Phone (Flutter)         │            │  Remote host (yours)          │
│                          │            │                               │
│  Terminal (xterm.dart)   │◄──SSH─────►│  sshd                         │
│  Session manager         │  (direct,  │   └── tmux: mobilecode-<id>   │
│  Secure key store        │   no relay)│        └── claude / codex /   │
└──────────────────────────┘            │             gemini CLI        │
                                        │        └── git, build, tests  │
                                        └───────────────────────────────┘
```

One link, deliberately: SSH from the phone to your host, carrying the terminal,
the agent, and every git operation that touches code. No third-party server
sits in the middle.

Cloning, committing, and pushing happen *on the host*, which already has
credentials and disk. The phone never becomes a git client, so we never have to
solve "large repo on a metered connection with 4 GB of storage."

## 2. Decisions and why

### 2.1 Flutter + dartssh2

`dartssh2` is a pure-Dart SSH2 client: PTY shell channels, SFTP, port
forwarding, password/pubkey/agent auth, ED25519 and RSA keys. Pure Dart means
no native bridging, no CocoaPods/Gradle divergence between platforms, and the
same code path on both. Since SSH is the entire product, the strongest SSH
library available drives the framework choice.

It pairs with `xterm` (xterm.dart), a Dart terminal emulator widget. The two
are commonly used together and speak the same primitives — bytes in, bytes out,
plus a resize hook.

### 2.2 Direct-from-device, no relay

The app opens SSH straight to your host. No infrastructure to run, nothing for
us to operate, and no third party positioned to observe your source code or
hold your keys. The security story is simply "it's an SSH client."

This has one real cost, addressed next.

### 2.3 tmux is the session model, not an add-on

**The problem.** iOS suspends a backgrounded app within seconds and tears down
its sockets; Android Doze does the same, less aggressively. Lock your phone
mid-refactor and a naive SSH client drops the connection — killing the agent's
process along with it, halfway through editing your files.

**The fix.** Every session runs inside a named tmux session on the host:

```
tmux new-session -A -s mobilecode-<session-id>
```

`-A` means attach-if-exists, create-otherwise, so one command covers both the
first connection and every reconnect. The agent is a child of tmux, not of our
SSH channel. Drop the connection and the agent keeps working; reattach and the
scrollback is intact and the TUI redraws itself.

This turns the direct-connection weakness into a non-issue for everything
except push notifications (see §7).

**Degradation.** Probe for `tmux`, then `screen`, then fall back to a raw PTY
with an explicit banner that the session is ephemeral. Never silently give the
user a session that dies.

### 2.4 Agents are CLIs on the host

We do not reimplement an agent harness. `claude`, `codex`, and `gemini` already
have file access, tool use, permission prompts, and repo context on the machine
where the code lives. The app's job is to launch them, render them, and make
them usable with a thumb.

An agent is described by a small declarative spec — binary name, launch
arguments, auth mode, whether it repaints an alternate screen buffer — so
supporting a new agent is a data change, not a code change.

### 2.5 Probing runs in a login shell

Before offering a list of agents we ask the host which ones it actually has.
That probe must run as `$SHELL -lc`, not as a bare command.

sshd executes one-shot commands in a **non-login, non-interactive** shell, so
`~/.profile`, `~/.bash_profile`, and `~/.zprofile` are never sourced. Agent
CLIs are usually installed through npm under nvm, whose `PATH` entry lives in
exactly those files. A bare `command -v claude` would report "not installed"
on a machine where `claude` runs perfectly on login — an authoritative-looking
wrong answer. Probing through a login shell reproduces the environment the
agent will actually launch in, which is the only environment whose answer
means anything.

The probe's output parser is deliberately lenient: a login shell may print a
MOTD, a last-login line, or a warning first, and none of that may turn into a
bogus availability result.

## 3. Agent authentication

The question "how does the user connect their agent account" has a different
answer than it first appears, because the agent runs on the host, not the phone.

**Delegated (default, recommended).** The CLI on the host is already logged in
— the user ran `claude login` there once. The app launches it and stays out of
the way. Nothing sensitive ever reaches the phone. This should be the paved
path and the one the onboarding flow teaches.

**Provisioned.** The user stores a provider API key in the app; the app injects
it into the remote session as an environment variable scoped to that session.

> Injection has a trap worth stating plainly: never send `export KEY=sk-...` as
> a shell command. It lands in shell history, and it is visible in `ps` and
> `/proc` to every other user on the box. Instead write the value to a
> mode-`600` file under the session's own directory and `source` it, or pass it
> through the SSH protocol's own environment channel where sshd's `AcceptEnv`
> permits. Delete the file on session teardown.

**OAuth from the app.** Because there is no backend, any OAuth flow must be
PKCE — there is nowhere to keep a client secret. Redirects go through a custom
URI scheme, using `ASWebAuthenticationSession` on iOS and Custom Tabs on
Android. The resulting token still has to reach the host, which lands us back
on the injection problem above.

This third mode is the most speculative part of the plan: each vendor's flow
differs and not all of them publish a public PKCE client suitable for a
third-party app. **Treat it as a research spike, not a committed feature** —
confirm per-vendor before promising it in the UI. Delegated auth covers the
actual user need without it.

## 4. Credentials and trust

| Material | Where it lives |
|---|---|
| SSH private keys | Platform secure storage, device-only |
| Provider API keys | Platform secure storage, device-only |
| Host name/address/port/user | Local database — not secret |
| Host key fingerprints | Local database, pinned |

Secure storage means `flutter_secure_storage`: on iOS the Keychain with
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, on Android AES-GCM content
encryption under a key wrapped by the hardware Keystore. (Note for anyone
following older guides: `EncryptedSharedPreferences` is deprecated as of the
plugin's v10 — the Jetpack Security library it wrapped was deprecated
upstream — and the plugin now uses its own ciphers.) Device-only accessibility
keeps keys out of iCloud Keychain sync and encrypted backups — an SSH key that
silently replicates to the user's other devices is not what they agreed to.
Host records reference keys by id; the key bytes are never in the database.

**Host key verification is mandatory.** Trust-on-first-use: show the
fingerprint on first connect, pin it, and refuse to connect on mismatch with a
loud, non-dismissable-by-accident warning. An SSH client that skips this hands
every keystroke and every key to anyone who can MITM the connection. There is
no "just this once" affordance.

Optional biometric gate (`local_auth`) before any private key is read.

## 5. Terminal on a phone

The hard part of this app is not SSH — it is that agent CLIs are full-screen
TUIs and phones have no Ctrl key.

- **Accessory key bar** above the keyboard: `Esc`, `Tab`, `Ctrl`, arrows,
  `Ctrl-C`, `/`, `|`, `-`. `Ctrl` and `Alt` are sticky modifiers.
- **Resize correctly.** Agent TUIs use the alternate screen buffer and repaint
  on `SIGWINCH`. Compute rows/cols from the actual glyph metrics and call
  dartssh2's terminal-size hook on every rotation and keyboard show/hide, or
  output wraps into garbage.
- **Font size** via pinch, persisted. 80 columns will not fit a phone in
  portrait; agents mostly cope, and landscape is the escape hatch.
- **Selection and paste** need a touch model — long-press to select, handles to
  extend — since there is no mouse.
- **Bracketed paste** on, so pasted code is not interpreted as keystrokes.

## 6. Module layout

```
lib/
  app/         bootstrap, router, theme
  core/        result/error types, logging, DI
  data/
    secure/    credential store (Keychain / Keystore)
    db/        hosts, sessions, known-hosts, repos
    models/
  features/
    hosts/     add/edit/list hosts, key management, TOFU prompts
    ssh/       dartssh2 client, PTY channel, tmux orchestration
    terminal/  xterm widget, accessory bar, resize plumbing
    agents/    agent registry, launch specs, auth modes
    github/    device-flow OAuth, repos, PRs
    files/     SFTP browse and edit
    settings/
```

Transport sits behind an interface (`SshTransport`) even though we chose direct
connections. If session-durability or push notifications later justify a relay,
it slots in underneath without the terminal, agent, and UI layers noticing.
This is cheap now and expensive to retrofit.

## 7. Known limits

- **Push notifications.** "Your agent finished" cannot work without something
  server-side staying connected. This is the one capability direct-from-device
  genuinely forecloses. Local notifications work only while the app is
  foregrounded, which is exactly when they are useless. Accept it, or revisit
  the relay decision specifically for this.
- **Vendor OAuth** — unresolved per §3, spike required.
- **Battery.** A live PTY holding the radio awake is expensive. Detach the SSH
  channel on background (tmux keeps the work alive) rather than fighting to
  hold the socket open.
- **App Store.** SSH clients are well-established precedent (Termius, Blink,
  Prompt), so the category is fine. Keep any "run arbitrary code" framing out
  of the listing.

## 8. Roadmap

The app's minor version tracks the completed phase — 0.1.0 for P1, 0.2.0 for
P2, 0.5.0 for P5 — with CI substituting its run number as the build number.
It stays below 1.0 while P1 remains unverified against a real sshd; the version
should not claim more than has been proven.

| Phase | Deliverable | State |
|---|---|---|
| **P0** | Scaffold: app boots, navigation, storage layer, models | done |
| **P1** | SSH + terminal + tmux — add a host, open a shell, reattach after backgrounding | code complete, unverified on a device |
| **P2** | Agent launch specs, remote detection, accessory bar | done |
| **P3** | GitHub integration | removed — see below |
| **P4** | Voice: personas assigned to Magpie TTS speakers | done, unverified against a live endpoint |
| **P5** | Vikram: the assistant — listen, answer, speak | done, unverified against a live endpoint |
| **P6** | SFTP file browser and editor | not started |
| **P7** | Biometrics, concurrent sessions, port forwarding, snippets | not started |

### Vikram (P5)

A full turn: microphone → text → model → `{emotion, text}` → speech → audio.
The panel is the reactor from the design study, drawn in a single
`CustomPainter` — forty rotating, glowing widgets would cost far more and
still not share a centre cleanly.

The controller takes its microphone, model, speech endpoint, and audio device
through interfaces. That is not ceremony: the failures worth catching here are
all sequencing — a reply landing after the screen closed, a second tap opening
the microphone under an in-flight request, a stop that leaves the panel stuck
on LISTENING — and none of them are reachable through a real device in a test.
Each turn carries a number; anything returning against a stale one is dropped.

Speech recognition uses the platform recogniser rather than an NVIDIA ASR
endpoint. It is free, needs no second function ID, and returns partial results,
which is what lets the transcript appear as the user speaks. On Android it also
needs a `queries` entry for `android.speech.RecognitionService`, or Android 11's
package visibility hides every recogniser and the device reports itself as
incapable rather than asking for permission.

Playback waits for the completion event before the turn ends, so the microphone
cannot reopen while the speaker is still talking and transcribe the assistant's
own voice.

The assistant degrades in steps rather than all at once: with no model it still
listens and says so; with a model but no speech endpoint it answers on screen
without speaking. Neither is treated as a failed turn.

### Voice (P4)

Personas are named characters the app speaks as. A persona owns a *speaker*,
not a voice name: the endpoint ships six emotional takes on each speaker
(Neutral, Angry, Disgusted, Fearful, Happy, Sad), and which one to use belongs
to the moment rather than the character — a failed deploy should not sound
like a finished one. So `Persona` stores the speaker key and the caller picks
the mood per utterance.

Two decisions worth recording:

- **Voice names are parsed positionally, never validated against a list.**
  NVIDIA adds speakers, locales, and emotions between releases, and a voice the
  endpoint offers but the app refuses to show is a bug the user cannot work
  around. `VoiceId` keeps the original string verbatim and round-trips it.
- **The `list_voices` response shape is not pinned.** It has been a bare array,
  an object keyed by locale, and an array of objects across Riva releases, so
  `parseVoiceNames` walks the decoded JSON and collects anything name-shaped.

The endpoint URL lives in `app_settings`; the API key lives in the credential
store, because the database ends up in a device backup and the key must not.

`LINEAR_PCM` responses arrive headerless, so `wrapPcmAsWav` prefixes a RIFF
header before playback; a response that already carries one passes through
untouched. Unwrapped, a player either rejects the bytes outright or renders
silence. Synthesis requests default to the voice's own render rate — 22.05 kHz
for Magpie — because the requested rate is also written into that header, and
a mismatch plays the clip at the wrong speed if the server returns native audio
rather than resampling.

### Codespaces, removed

A GitHub Codespaces integration was built and then taken out: sign-in by
device flow, listing and starting Codespaces, and SSH tunnelled over a
WebSocket through a forwarded port, since a Codespace exposes no SSH endpoint
of its own.

The transport worked — SSH reached a Codespace through GitHub's tunnel from a
phone. What made it not worth keeping was the setup around it: a bridge
process and an authorised key inside each Codespace, which in turn needs
`.devcontainer` config committed to every repository you want reachable. VS
Code avoids all of that by using its own protocol over Dev Tunnels, authorised
by a GitHub token rather than SSH keys — reproducing that means implementing
an undocumented protocol with no Dart SDK.

The code is in the history if it is ever wanted. `WebSocketSshSocket` and
`SshKeygen` survive: both are general SSH capabilities, and the integration
test built on them is the project's only coverage against a real `sshd`.

P1 is the milestone that proves the product, and it is the next thing to
confirm: the code paths exist and are unit-tested, but nothing has yet run
against a real sshd on real hardware. Until someone adds a host and watches an
agent survive a locked phone, treat P1 as unproven.
