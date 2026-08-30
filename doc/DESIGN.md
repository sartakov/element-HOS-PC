# Element for HarmonyOS — Design Document

## 1. Overview

**Element for HarmonyOS** is a native HarmonyOS application (ArkTS) that runs the real
element-web Matrix client — the open-source secure messaging and collaboration app from
Element / New Vector — on HarmonyOS devices.

Element-web (https://github.com/element-hq/element-web) is a large (~322,000 lines of
TypeScript/TSX across ~2,158 source files) React + Redux single-page application. It is
deeply coupled to web platform features: the DOM, WebRTC, the Olm/WebAssembly end-to-end
encryption library, IndexedDB, Web Workers, Web Sockets and Service Workers.

This project takes the pragmatic production approach of **embedding the built element-web
static bundle inside an ArkWeb (Web) component**, served from a **local HTTP server** running
inside the app, rather than attempting a line-by-line native ArkTS rewrite (a multi-year,
multi-engineer effort tracked separately by the official project).

## 2. Goals

- Deliver a fully functional Element client on HarmonyOS today.
- Reuse the latest upstream element-web without forking or rewriting application logic.
- Bundle all client assets (JS, CSS, themes, i18n, fonts, config) **inside** the app for a
  self-contained install, while still reaching Matrix homeservers over the network.
- Give the WebView a real `http://` origin so `fetch()`, config loading, Service Workers and
  IndexedDB all work.
- Verify a clean end-to-end build (ArkTS compile + HAP/app packaging).

## 3. Non-goals

- Rewriting element-web into native ArkTS UI components (handled by the official project).
- Replacing the upstream client architecture or its E2EE, sync, or storage internals.
- Offline-first operation independent of the network.

## 4. Architecture

```
┌────────────────────────────────── HarmonyOS App ──────────────────────────────────┐
│                                                                                  │
│  products/default/src/main/ets/pages/Index.ets  (@Entry)                         │
│    ├─ RawfileExtractor.copyToSandbox()                                           │
│    │     rawfile/element/*  →  filesDir/element/  (663 files, once)              │
│    ├─ LocalHttpServer.start()                                                    │
│    │     listens on 127.0.0.1:<port>, serves filesDir/element/                   │
│    └─ Web({ src: http://127.0.0.1:<port>/ })  (ArkWeb)                           │
│            │                                                                     │
│            ▼                                                                     │
│  ┌────────────────────────────────────────────────────────────┐                  │
│  │  element-web static bundle over HTTP                       │                  │
│  │    index.html  prelude.js  config.json  bundles/ …         │                  │
│  └────────────────────────────────────────────────────────────┘                  │
│            │  fetch()/ServiceWorker/IndexedDB all OK over http:// origin         │
└──────────────────────────────────────────────────────────────────────────────────┘
            ▼  HTTPS to Matrix homeserver (matrix-client.matrix.org)
```

### Component flow

1. **Entry page** (`Index.ets`) calls `startElement()` from `aboutToAppear()`.
2. `RawfileExtractor` copies the packaged `rawfile/element/` tree into
   `context.filesDir + '/element'`. A `.extracted` marker file records completion so the
   copy runs only once (663 files, ~136 MB — a few seconds).
3. `LocalHttpServer` binds a `TCPSocketServer` to `127.0.0.1:0` (ephemeral port), reads the
   allocated port, and serves the sandbox directory with correct `Content-Type`,
   `Content-Length`, and `Connection: close` semantics.
4. The ArkWeb `Web` component loads `http://127.0.0.1:<port>/`. Because the page now has a
   real HTTP origin, element-web's `fetch(config.json)` and `fetch(i18n/languages.json)`
   succeed, and its Service Worker/IndexedDB calls work.

## 5. Why `resource://rawfile/` was abandoned

The first implementation loaded the bundle directly with `Web({ src: $rawfile('element/index.html') })`.
On-device logs showed it **partially** worked — `<script>`/`<link>`/`<img>` sub-resources
loaded, `onPageEnd` fired — but the app stayed on a blank screen because:

- The document origin under `resource://` is `null`.
- element-web calls `fetch()` for `config.json` and `i18n/languages.json`; the browser
  rejects this with:
  > Fetch API cannot load resource://rawfile/element/config.json. URL scheme "resource" is not supported.
- Service Worker registration also fails on the `null` origin.

These are inherent limits of the read-only `resource://` scheme. Serving over `http://` from
a local server is the only way to give the page a proper origin.

## 6. Layout & the `mobile_guide/` redirect

ArkWeb reports a **desktop** user agent by default, so element-web chooses its wide
three-panel desktop layout (looks "wider than the screen" on a phone). To render the phone
layout the app forces a **mobile user agent** on the `Web` component.

That change exposed a second problem: element-web has an **unconditional** mobile redirect in
`apps/web/src/vector/index.ts` — when `navigator.userAgent` matches `/Android/`, it navigates
to `mobile_guide/` (its native-app download page) unless
`sessionStorage.skip_mobile_redirect === "true"`. Two cooperating mechanisms stop this:

1. **`prelude.js`** — an external script referenced by `index.html` *before* the element-web
   bundle. It sets `sessionStorage.setItem("skip_mobile_redirect", "true")`. It must be an
   **external** file (not an inline `<script>`) because element-web's CSP
   (`script-src 'self'`) blocks inline scripts.
2. **`config.json`** sets `mobile_guide_toast: false`, which also disables the MobileGuide
   toast that could navigate to the same page.

## 7. Key components

### `LocalHttpServer.ets` (`products/default/src/main/ets/local/`)
- Uses `socket.constructTCPSocketServerInstance()` from `@kit.NetworkKit`.
- `start(): Promise<string>` — `listen({ address: '127.0.0.1', port: 0, family: 1 })`, then
  `getLocalAddress()` for the allocated port, returns `http://127.0.0.1:<port>`.
- Per-connection: buffers `message` chunks until `\r\n\r\n`, parses the request line,
  percent-decodes the path, resolves it against the root with traversal protection, and
  serves the file with the correct MIME type. Handles `GET`/`HEAD`; `Connection: close`.

### `RawfileExtractor.ets` (`products/default/src/main/ets/local/`)
- `copyToSandbox(ctx, rawRoot, destRoot)` — recursively walks the rawfile tree via
  `resourceManager.getRawFileList()` and writes each file with `fileIo`. A `.extracted`
  marker prevents re-copying.
- `isExtracted(rootDir)` — true if the `.extracted` marker exists.

### `Index.ets` (`products/default/src/main/ets/pages/`)
- Hosts the `Web` component, wired up in `startElement()` as above.
- `onErrorReceive` only treats **main-frame** failures as fatal; benign sub-resource errors
  (e.g. a CORS-blocked PWA `manifest.json`) are ignored.
- Shuts the server down in `aboutToDisappear()`.

## 8. Permissions

Declared in `products/default/src/main/module.json5`:
- `ohos.permission.INTERNET` — required for the local HTTP server and for the WebView to reach
  Matrix homeservers.
- `ohos.permission.GET_NETWORK_INFO` — network-state visibility.

The local server binds only to loopback (`127.0.0.1`), so no external exposure.

## 9. Project layout (post-cleanup)

```
Element/
├── AppScope/app.json5                      # bundle id, version, app icon
├── build-profile.json5                     # product/signing/target config
├── hvigorfile.ts, hvigor/, oh-package.json5  # build tooling
├── doc/DESIGN.md                           # this document
├── README.md                               # quick-start guide
└── products/default/                       # single entry (HAP) module
    └── src/main/
        ├── ets/pages/Index.ets             # ArkWeb host page
        ├── ets/local/LocalHttpServer.ets   # HTTP file server
        ├── ets/local/RawfileExtractor.ets  # rawfile → sandbox extractor
        ├── ets/defaultability/DefaultAbility.ets
        ├── module.json5                    # permissions + main ability
        └── resources/
            ├── rawfile/element/            # ★ the built element-web bundle
            └── base/{element,media,profile}
```

All DevEco template demo scaffolding (the `common`, `adaptiveLayout`, `responsiveLayout`
modules; the `AdaptiveIndex`/`ResponsiveIndex`/`SystemCapabilitiesIndex` pages; the backup
extension; and their resources) was removed.

## 10. Build & verification

Build from **DevEco Studio** or the CLI:

```bash
export NODE_HOME=/Applications/DevEco-Studio.app/Contents/tools/node
export PATH="$NODE_HOME/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME
export JAVA_HOME=/Applications/DevEco-Studio.app/Contents/jbr/Contents/Home

hvigorw assembleApp --mode project -p product=default --no-daemon
```

- `DEVECO_SDK_HOME` must point to the **parent** of the SDK `default/` dir.
- The `PackageApp` step needs a Java runtime (`JAVA_HOME`).
- Signing config is read from `build-profile.json5`; regenerate certificates in DevEco Studio
  if they change.

Outputs:
- HAP: `products/default/build/default/outputs/default/default-default-signed.hap`
- App: `build/outputs/default/Element-default-signed.app`

## 11. Rebuilding the element-web bundle

```bash
cd ../element-web
pnpm install
pnpm exec nx run element-web:prebuild:module_system
pnpm exec nx run element-web:prebuild:rethemendex
pnpm exec nx run element-web:build      # → apps/web/webapp
mkdir -p ../Element/products/default/src/main/resources/rawfile/element
cp -R apps/web/webapp/* ../Element/products/default/src/main/resources/rawfile/element/
```

Then re-add `prelude.js` to `index.html` (a `<script src="prelude.js">` before the bundle)
and set `"mobile_guide_toast": false` in `config.json`, as described in section 6.

## 12. Known limitations & future work

| Area | Status / Note |
|------|---------------|
| DOM / React rendering | Runs in WebView; not native ArkUI components |
| Layout / viewport | Mobile UA forces the phone layout; the ArkWeb viewport scale may need per-device tuning (`layoutMode`, `viewportWidth`, `zoomAccess`) |
| Service workers / PWA | Used over the `http://` origin; offline caching limited by WebView context |
| Voice/video (Element Call) | Bundled; depends on runtime media grants |
| Native integration | Future: bridge native capabilities (share, camera, notifications, biometrics) into element-web via `javaScriptProxy` |

### Recommended follow-ups
1. **Viewport tuning**: experiment with `Web` `layoutMode(WebLayoutMode.FIT_CONTENT)`,
   a `viewport` meta / `viewportWidth`, and `zoomAccess(false)` to make the page fit phones
   and 2-in-1s cleanly.
2. **Signing**: keep `signingConfigs` in `build-profile.json5` current for device deployment.
3. **Native bridge**: expose native HarmonyOS APIs to element-web via `javaScriptProxy`.
4. Trim optional asset groups (e.g. the ~43 MB Element Call widget) to shrink the HAP.
