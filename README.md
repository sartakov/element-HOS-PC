# Element for HarmonyOS

A native HarmonyOS (ArkTS) application that runs the real **element-web** Matrix client
(https://github.com/element-hq/element-web) inside an ArkWeb (Web) component.

Element-web is a large (~322k LOC) React/TypeScript single-page application that depends
heavily on web platform features: DOM, WebRTC, the Olm/WebAssembly E2EE library,
`fetch()`, Service Workers and IndexedDB. Because it cannot be rewritten line-by-line into
native ArkTS, this project embeds the **built element-web static bundle** in an ArkWeb
WebView and serves it from a **local HTTP server** running inside the app.

## How it works

```
┌────────────────────────────── HarmonyOS App (com.sys_sec.element) ─────────────────────────────┐
│                                                                                              │
│  Index.ets (ArkUI @Entry)                                                                    │
│    │ on launch:                                                                              │
│    │  1. RawfileExtractor copies rawfile/element/* (571 files) → filesDir/element            │
│    │  2. LocalHttpServer starts on http://127.0.0.1:8448 serving that directory                    │
│    │  3. ArkWeb `Web` loads http://127.0.0.1:8448/                                                 │
│    ▼                                                                                         │
│  ┌──────────────────────────────────────────────────────────────────────────────────┐        │
│  │  element-web static bundle (packaged as rawfile, served over HTTP)                │        │
│  │    index.html  prelude.js  config.json  bundles/ themes/ i18n/ fonts/ …           │        │
│  └──────────────────────────────────────────────────────────────────────────────────┘        │
│    ▲ fetch() / config.json / ServiceWorker / IndexedDB all work over the http:// origin      │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
        │  HTTPS to Matrix homeserver (e.g. https://matrix-client.matrix.org)
        ▼
   Matrix federation / account data / sync
```

### Why a local HTTP server (not `resource://rawfile/`)
The initial implementation loaded the bundle directly from `resource://rawfile/element/`.
That works only for `<script>`/`<link>`/`<img>` sub-resources; element-web's own JavaScript
calls `fetch()` to load `config.json` and `i18n/languages.json`, and registers a Service
Worker. Under the `resource://` scheme the document origin is `null`, so `fetch()` fails
("URL scheme resource is not supported") and the app cannot initialize. Serving the bundle
from a real `http://127.0.0.1` origin fixes all of that.

### Layout / redirect handling
ArkWeb reports a desktop user agent by default, so element-web renders its wide three-panel
desktop layout. This app:
- forces a **mobile user agent** so element-web renders its phone layout, and
- ships a tiny `prelude.js` (injected before the app bundle) that sets
  `sessionStorage.skip_mobile_redirect = "true"` so element-web does **not** redirect to its
  native-app download page (`mobile_guide/`). The `config.json` also sets
  `mobile_guide_toast: false`.

## Repository layout (after cleanup)

```
Element/
├── AppScope/                       # app-level config + icons
├── products/default/               # the single entry (HAP) module
│   └── src/main/
│       ├── ets/
│       │   ├── pages/Index.ets         # ArkWeb host page (the Element UI)
│   │   ├── local/LocalHttpServer.ets    # fixed-port (8448) HTTP/1.1 file server (ArkTS)
│   │   ├── local/NotificationBridge.ets # Web Notifications API → NotificationKit bridge
│   │   ├── local/RawfileExtractor.ets   # extracts rawfile bundle → sandbox
│       │   ├── defaultability/DefaultAbility.ets   # UIAbility (close-to-taskbar on 2-in-1)
│       │   └── entryability/EntryAbilityStage.ets  # ability-stage (keeps process alive)
│       ├── module.json5             # permissions, main ability, ability-stage
│       └── resources/
│           ├── rawfile/element/     # ★ the built element-web bundle (571 files, ~68 MB)
│           └── base/                # strings, colors, app icons
├── doc/DESIGN.md                    # detailed design document
├── build-profile.json5              # product/signing/version config
├── hvigorfile.ts / hvigor/          # build tooling config
└── oh-package.json5                 # HarmonyOS package manifest
```

## Prerequisites

- **DevEco Studio** (HarmonyOS SDK API 21 / 6.0.1) — bundles Node, Hvigor and ohpm.
- **Node.js >= 22** and **pnpm** (only needed if you rebuild the element-web bundle).
- The **element-web** source + build (to regenerate `rawfile/element/`), or use the bundle
  already committed under `products/default/src/main/resources/rawfile/element/`.

## Building the HarmonyOS app

From DevEco Studio (recommended): **File → Open** this project, then **Build**.

Or from the CLI:

```bash
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export PATH="$NODE_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home

hvigorw assembleApp --mode project -p product=default --no-daemon
```

Outputs (unsigned):
- HAP: `products/default/build/default/outputs/default/default-default-unsigned.hap`

The CLI build is **unsigned** — signing is done by `compile_and_run.sh` (below) with
the AppGallery key material in `$SIGN_HOME`; no `signingConfigs` block is kept in
`build-profile.json5` (avoids committing credentials).

## Running / deploying

Install the signed HAP over USB or Wi-Fi with hdc, then launch:

```bash
hdc install -r "$HOME/signing/Element-PC/harmony/Element-PC-debug-signed.hap"
hdc shell aa start -a DefaultAbility -b com.sys_sec.element
```

Or use the one-shot build+sign+deploy+launch script (see `compile_and_run.sh`):

```bash
MODE=debug ./compile_and_run.sh <device-ip>:<port>       # build, sign, install, launch
MODE=debug ./compile_and_run.sh --wipe <device-ip>:<port>  # same, but clear all app data first
MODE=release ./compile_and_run.sh                         # build .app + release-sign (store)
```

- `MODE=debug` (default) signs with the AGC debug cert/profile for bundle
  `com.sys_sec.element` and installs on the device.
- `MODE=release` builds the app package (`assembleApp`), signs the `.app` with
  the AGC **release** cert/profile, and stops before install — release-signed
  `.app` cannot be sideloaded (error 9568322) and must go through AppGallery
  Connect.
- Signing material lives in `$SIGN_HOME` (default `~/signing/Element-PC/harmony`):
  `app-debug.cer/.p7b`, `app-release.cer/.p7b`, and the keystores under `keytool/`.
  Generate the release keypair + CSR with `scripts/generate-release-key.sh`.

By default the script reinstalls **in place** (`install -r`) and **preserves app data**, so
the saved login/session survives rebuilds — you do not have to sign in again after every
deploy. Pass `--wipe` for a clean slate (e.g. after changing signing certificates), which
uninstalls the app first and clears all data including the stored session.

On first launch the app copies the ~68 MB bundle into the app sandbox (a few seconds) and
starts the local server, then shows the Element login screen.

## Rebuilding the element-web bundle (when upstream changes)

Grab the official prebuilt release tarball and restage it (recommended — the
stable build, no local toolchain needed):

```bash
# download from https://github.com/element-hq/element-web/releases
# (e.g. element-v1.12.27.tar.gz)
RAW=products/default/src/main/resources/rawfile/element
rm -rf "$RAW" && mkdir -p "$RAW"
tar -xzf /path/to/element-v1.12.27.tar.gz -C "$RAW" --strip-components=1
```

Or build from source (dev setup with Node >= 22 + pnpm):

```bash
cd ../element-web
pnpm install
pnpm exec nx run element-web:prebuild:module_system
pnpm exec nx run element-web:prebuild:rethemendex
pnpm exec nx run element-web:build          # → apps/web/webapp
mkdir -p products/default/src/main/resources/rawfile/element
cp -R ../element-web/apps/web/webapp/* products/default/src/main/resources/rawfile/element/
```

Then re-apply the project overrides and the notifier patch (which restores the
`doc/DESIGN.md` §7b bundle edit and bumps the `prelude.js?v=` cache-buster):

```bash
RAW=products/default/src/main/resources/rawfile/element
# carry the project prelude.js + config.json forward from the previous bundle
cp "$RAW.previous/prelude.js" "$RAW/prelude.js"
cp "$RAW.previous/config.json" "$RAW/config.json"
# inject <script src="prelude.js?v=N"> into index.html before the bundle script
python3 scripts/patch-notifier.py             # §7b notifier patch + bump cache-buster
find "$RAW" -name "*.map" -delete            # strip source maps (~51 MB saved)
echo v1.12.27 > "$RAW/version"
```

## Notes & known limitations

- The client runs in a WebView; it is the full element-web app, not a native ArkUI rewrite.
- Session/IndexedDB persistence lives in the app sandbox. The local server binds a **fixed**
  port (`127.0.0.1:8448`), so the page origin stays constant across relaunches and the saved
  login/session survives restarts (no re-login). Reinstalling with `hdc install -r` preserves
  this data; **uninstalling the app wipes it**, so `compile_and_run.sh` preserves data by
  default and only uninstalls when told to with `--wipe`.
- On 2-in-1 devices, closing the window (**X**) hides the app to the taskbar with the process
  kept alive; clicking the taskbar/dock icon reopens it still logged in (see `doc/DESIGN.md`
  §7a).
- The configured homeserver is set in `rawfile/element/config.json` (currently
  `https://matrix-client.matrix.org`).
- Service workers are used (over the `http://` origin) but offline/PWA caching is limited by
  the WebView context.
- **Notifications.** element-web delivers message notifications from the sync loop running
  *inside the WebView*, via the Web Notifications API (`new window.Notification(...)`) — which
  ArkWeb otherwise silently drops. A shim in `prelude.js`:
  - auto-enables element-web's own device-level setting (`notifications_enabled` in
    localStorage, otherwise **off by default** — the gate that silently blocks every
    real notification);
  - replaces `window.Notification` and forwards constructor calls to a native bridge
  (`NotificationBridge.ets` → `@kit.NotificationKit`).
  The shipped element-web bundle is also patched (see `doc/DESIGN.md` §7b) so a per-device
  "silenced" flag can't suppress popup notifications on this client. So while the app is
  **resident** (normal use, incl. the 2-in-1 close-to-taskbar mode) incoming messages produce
  an OS notification and update the launcher badge; clicking a notification reopens/focuses
  the app. They do **not** work while the app process is fully terminated (that would require
  a Matrix push gateway + background polling; not implemented). See also `doc/DESIGN.md` §12.
- The on-screen layout currently uses the mobile user agent; the WebView viewport scale may
  need tuning per device. See `doc/DESIGN.md` for details.
