# MobileCode

Code from your phone. MobileCode connects over SSH to a machine you already own
— a dev box, a VPS, your laptop — and drives the coding agents installed there
(`claude`, `codex`, `gemini`) through a terminal built for a small screen.

No relay server. The phone talks straight to your host, so nothing sits in the
middle of your source code or your keys.

## How it works

Every session runs inside a `tmux` session on your host. That matters more than
it sounds: iOS suspends a backgrounded app within seconds and kills its
sockets, so a naive SSH client would take the agent down with it — potentially
mid-edit. Under tmux the agent belongs to the tmux server instead. Lock your
phone, and it keeps working; reopen the app and you reattach to it, scrollback
intact.

## Status

Early. The scaffold and the SSH/terminal/tmux layer are written and unit
tested, but **nothing has run against a real host yet** — see the roadmap in
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for what is done and what is
not.

## Requirements

- Flutter 3.44+
- A host you can reach over SSH, with `tmux` installed
- An agent CLI installed and already logged in on that host

## Development

```sh
flutter pub get
flutter analyze
flutter test
flutter run          # needs the Android SDK or Xcode
```

## Codespaces

The app can open a terminal on a GitHub Codespace as well as on your own
machines. A Codespace exposes no public SSH endpoint, so this runs SSH inside a
WebSocket over a forwarded port — see [`docs/CODESPACES.md`](docs/CODESPACES.md)
for why and how, and `tools/codespace-bridge.sh` for the one-time setup inside
each Codespace.

Signing in to GitHub uses the OAuth **device flow**, which needs no client
secret — the right choice for an app that ships to phones. It does need a
client id, which is per-installation and so cannot be hardcoded:

1. Register a GitHub OAuth App and enable **Device flow** on it.
2. Build with the id:

```sh
flutter build apk --release --dart-define=GITHUB_CLIENT_ID=Ov23li...
```

Without it, the Codespaces tab explains what is missing rather than failing
mysteriously. The requested scopes are `repo`, `codespace`, and `read:user`.

## Getting a build onto your phone

Actions → **Build app** → *Run workflow*. Pick `android`, `ios`, or `both` and
a build mode. When it finishes, the artifacts are at the bottom of the run's
summary page.

GitHub always wraps artifacts in a zip, so what downloads is
`mobilecode-android-release-7.zip` — unzip it to get the file inside.

### Android

Copy the `.apk` to the phone, open it, and allow installing from unknown
sources when prompted.

#### Installing updates over the top

Without a signing key configured, each CI run signs with a **different** key:
Gradle generates `~/.android/debug.keystore` whenever one is missing, and CI
runners start clean every time. Android refuses to update an app whose
signature changed, so each new build can only be installed by uninstalling
first — which destroys your hosts, host key pins, and stored keys.

Configure a stable key once and builds install as updates. Generate a keystore:

```sh
keytool -genkeypair -v \
  -keystore mobilecode.jks -storetype PKCS12 \
  -keyalg RSA -keysize 2048 -validity 10000 \
  -alias mobilecode \
  -dname "CN=MobileCode, O=MobileCode, C=IN"
```

Then add four repository secrets:

```sh
base64 -w0 mobilecode.jks | gh secret set MOBILECODE_KEYSTORE_BASE64
gh secret set MOBILECODE_KEYSTORE_PASSWORD   # the store password you chose
gh secret set MOBILECODE_KEY_PASSWORD        # the key password you chose
gh secret set MOBILECODE_KEY_ALIAS --body mobilecode
```

**Keep `mobilecode.jks` safe and do not commit it.** Lose it and you can never
update an installed app again — only uninstall and start over. A signing key
in a public repo would let anyone build an APK that Android accepts as an
update to yours.

With no keystore secret set, builds still work and fall back to debug signing;
you just keep having to uninstall between versions.

This key is for sideloading. The Play Store has its own signing requirements.

### iOS

Worth knowing before you run it: **Apple does not let you install an app by
downloading it on the phone.** The workflow produces an *unsigned* IPA, because
signing requires Apple certificates this repo does not have. To get it running
you need a computer and a sideloading tool — Sideloadly or AltStore — which
re-signs the IPA with your own Apple ID and installs it over USB.

With a free Apple ID that gives you an app that stops working after 7 days and
a limit of 3 sideloaded apps; you re-sign to renew. A paid Apple Developer
account ($99/year) raises that to a year.

If you want an iOS build that installs directly, the path is a paid developer
account plus a signing certificate and provisioning profile stored as repo
secrets, and distribution through TestFlight. That is a real change to this
workflow rather than a setting — say the word and I will wire it up.

## Layout

```
lib/
  app/         bootstrap, providers, theme
  core/        shell quoting and other primitives
  data/        models, sqlite, secure credential store
  features/
    agents/    declarative launch specs per agent CLI
    ssh/       dartssh2 transport, tmux orchestration, host key pinning
    terminal/  xterm view, session controller, accessory key bar
    hosts/     host list and host form
docs/
  ARCHITECTURE.md
```

## Security

- SSH keys, passwords, and API keys live in the iOS Keychain / Android
  Keystore, marked device-only so they never sync to iCloud or a backup.
- Host keys are pinned on first use. A changed host key blocks the connection
  and cannot be clicked through — clear the pin in settings if you know the
  host was rebuilt.
- Agent credentials are best left on the host (`claude login` there once). The
  app never needs them.
