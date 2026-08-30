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
┌────────────────────────────── HarmonyOS App (com.example.element) ─────────────────────────────┐
│                                                                                              │
│  Index.ets (ArkUI @Entry)                                                                    │
│    │ on launch:                                                                              │
│    │  1. RawfileExtractor copies rawfile/element/* (663 files) → filesDir/element            │
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
│       │   ├── local/LocalHttpServer.ets    # fixed-port (8448) HTTP/1.1 file server (ArkTS)
│       │   ├── local/RawfileExtractor.ets   # extracts rawfile bundle → sandbox
│       │   ├── defaultability/DefaultAbility.ets   # UIAbility (close-to-taskbar on 2-in-1)
│       │   └── entryability/EntryAbilityStage.ets  # ability-stage (keeps process alive)
│       ├── module.json5             # permissions, main ability, ability-stage
│       └── resources/
│           ├── rawfile/element/     # ★ the built element-web bundle (663 files, ~136 MB)
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

Outputs:
- Signed HAP: `products/default/build/default/outputs/default/default-default-signed.hap`
- Signed app package: `build/outputs/default/Element-default-signed.app`

Note: the CLI build requires a `signingConfigs` block in `build-profile.json5`. This repo
references one (`default`) pointing at your local `~/.ohos/config/*` certificates; regenerate
it in DevEco Studio if your certificates change.

## Running / deploying

Install the signed HAP over USB or Wi-Fi with hdc, then launch:

```bash
hdc install -r products/default/build/default/outputs/default/default-default-signed.hap
hdc shell aa start -a DefaultAbility -b com.example.element
```

On first launch the app copies the ~136 MB bundle into the app sandbox (a few seconds) and
starts the local server, then shows the Element login screen.

## Rebuilding the element-web bundle (when upstream changes)

```bash
cd ../element-web
pnpm install
pnpm exec nx run element-web:prebuild:module_system
pnpm exec nx run element-web:prebuild:rethemendex
pnpm exec nx run element-web:build          # → apps/web/webapp
```

Restage into the project (keep `prelude.js` and the `mobile_guide_toast: false` config):

```bash
mkdir -p products/default/src/main/resources/rawfile/element
cp -R ../element-web/apps/web/webapp/* products/default/src/main/resources/rawfile/element/
```

## Notes & known limitations

- The client runs in a WebView; it is the full element-web app, not a native ArkUI rewrite.
- Session/IndexedDB persistence lives in the app sandbox. The local server binds a **fixed**
  port (`127.0.0.1:8448`), so the page origin stays constant across relaunches and the saved
  login/session survives restarts (no re-login).
- On 2-in-1 devices, closing the window (**X**) hides the app to the taskbar with the process
  kept alive; clicking the taskbar/dock icon reopens it still logged in (see `doc/DESIGN.md`
  §7a).
- The default homeserver is set in `rawfile/element/config.json` (currently
  `https://matrix-client.matrix.org`).
- Service workers are used (over the `http://` origin) but offline/PWA caching is limited by
  the WebView context.
- The on-screen layout currently uses the mobile user agent; the WebView viewport scale may
  need tuning per device. See `doc/DESIGN.md` for details.
