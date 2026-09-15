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
│    │     rawfile/element/*  →  filesDir/element/ (571 files; re-extracted   │
│    │     only when the shipped prelude/index/bundle signature changes)      │
│    ├─ LocalHttpServer.start()                                                    │
│    │     listens on 127.0.0.1:8448, serves filesDir/element/                     │
│    └─ Web({ src: http://127.0.0.1:8448/ })  (ArkWeb)                             │
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
   `context.filesDir + '/element'`. A `.extracted` marker records a **signature** of the
   shipped assets (FNV-1a hashes of `prelude.js` and `index.html` plus the element-web bundle
   hash-directory name). On later starts the copy is skipped only when that signature still
   matches, so `install -r` over an older extraction re-extracts whenever anything we ship
   changed (571 files, ~68 MB — a few seconds), while leaving IndexedDB untouched.
3. `LocalHttpServer` binds a `TCPSocketServer` to the **fixed** loopback address
   `127.0.0.1:8448` (the same well-known port the mobile element-HOS build uses), reads the
   allocated port, and serves the sandbox directory with correct `Content-Type`,
   `Content-Length`, and `Connection: close` semantics.
4. The ArkWeb `Web` component loads `http://127.0.0.1:8448/`. Because the page now has a
   real HTTP origin, element-web's `fetch(config.json)` and `fetch(i18n/languages.json)`
   succeed, and its Service Worker/IndexedDB calls work.

> **Fixed port (8448) & login persistence.** The port is *fixed* (not ephemeral) so the page
> origin is **constant across app relaunches**. element-web stores its login session, device
> keys and crypto data in IndexedDB, which is keyed by origin. With an ephemeral port
> (`127.0.0.1:<n>` changes every launch) the origin would differ on each run and the saved
> session would be unreachable, forcing re-login. Binding to the same `127.0.0.1:8448` every
> time keeps the origin stable and IndexedDB readable, so the user stays logged in across
> restarts. (The `.extracted` marker now stores a signature and only forces a re-copy when
> the shipped assets change — see section 2.) Reinstalling the HAP with
> `hdc install -r` preserves this data — the session is only lost when the app is
> **uninstalled**, so `compile_and_run.sh` preserves data by default and uninstalls only when
> given `--wipe`.

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
- `start(): Promise<string>` — `listen({ address: '127.0.0.1', port: 8448, family: 1 })`, reads
  the allocated port via `getLocalAddress()`, and returns `http://127.0.0.1:8448`. The fixed
  port keeps the origin (and therefore the IndexedDB login/session store) stable across
  relaunches. If `listen()` cannot bind 8448, the platform **silently allocates a random
  port** instead of failing; the server therefore verifies the actually-bound port via
  `getLocalAddress()` and, when it differs, closes and retries up to `MAX_BIND_ATTEMPTS`
  times before giving up. This prevents the origin from silently changing between launches
  (which would orphan the saved session in IndexedDB).
- Per-connection: buffers `message` chunks until `\r\n\r\n`, parses the request line,
  percent-decodes the path, resolves it against the root with traversal protection, and
  serves the file with the correct MIME type. Handles `GET`/`HEAD`; `Connection: close`.

### `RawfileExtractor.ets` (`products/default/src/main/ets/local/`)
- `copyToSandbox(ctx, rawRoot, destRoot)` — recursively walks the rawfile tree via
  `resourceManager.getRawFileList()` and writes each file with `fileIo`, then stores the
  current asset signature in a `.extracted` marker.
- `isCurrent(ctx, destRoot)` — recomputes the signature and returns true when the sandbox
  copy still matches the shipped assets, so `install -r` over an older extraction keeps
  the served bundle fresh (re-extracts only when something really changed) while never
  touching IndexedDB. The signature is an FNV-1a hash of `prelude.js` plus `index.html`,
  plus the sorted `element/bundles` hash-directory listing from both rawfile and sandbox.
- `Index.ets` calls `isCurrent()` at startup and falls back to `copyToSandbox()` only when
  it reports stale.

### `Web` component cache policy (`Index.ets`)
- The `Web` component is created with `.cacheMode(CacheMode.None)`, and `index.html`
  references `prelude.js?v=N` with a bumped version. Together they defeat ArkWeb's HTTP
  cache and any stale service-worker copy, so every launch always serves the freshly
  extracted local assets (important because the notifier/shim edits live in these files).
  The `scripts/patch-notifier.py` helper bumps `?v=N` when the notifier patch is re-applied
  after a bundle restage.

### `Index.ets` (`products/default/src/main/ets/pages/`)
- Hosts the `Web` component, wired up in `startElement()` as above.
- `onErrorReceive` only treats **main-frame** failures as fatal; benign sub-resource errors
  (e.g. a CORS-blocked PWA `manifest.json`) are ignored.
- Shuts the server down in `aboutToDisappear()`.

## 7a. 2-in-1 "close-to-taskbar" behavior

On 2-in-1 (PC-style) devices, pressing the window **X** should *not* quit a messenger — it
should hide the app to the taskbar/dock with the process kept alive, and reopen on the icon
click. Two cooperating mechanisms implement this:

- **`EntryAbilityStage.ets`** (`products/default/src/main/ets/entryability/`) — registered as
  the module-level stage via `srcEntry` in `module.json5`. Its
  `onPrepareTerminationAsync(): Promise<AbilityConstant.PrepareTermination>` returns
  `CANCEL`, so when the user chooses to end the app from the dock/taskbar the process stays
  resident instead of terminating.
- **`DefaultAbility.ets`** — the single `UIAbility` (declared `launchType: "singleton"`):
  - keeps the main `Window` (from `onWindowStageCreate`) for later manipulation,
  - overrides `onPrepareToTerminate(): boolean` to return `true` (cancel the close) **and**
    call `window.minimize()`, parking the window in the taskbar,
  - overrides `onNewWant()` to restore the window via `window.recover()` when the user
    reopens the app from the taskbar/dock icon (a hot launch on the singleton ability).

Requires `ohos.permission.PREPARE_APP_TERMINATE`; `onPrepareToTerminate` applies only on
2-in-1 devices and only to a normal user close.

## 7b. Notifications (Web Notifications API → NotificationKit bridge)

element-web plays message sounds and shows notifications from the sync loop running **inside
the WebView**. It uses the Web Notifications API (`new window.Notification(title, {body,
silent, icon})`, `Notification.permission`, `Notification.requestPermission`) from its
`Web ChromePlatform`. ArkWeb accepts these calls, but they never produce an OS notification —
so on a stock build the in-app sound plays while nothing reaches the notification center or
the launcher badge.

Because the bundle cannot be rewritten line-by-line, the app intercepts the API instead:

0. **The real gate.** element-web's notifier (`Notifier.evaluateEvent` in the bundled
   `8406.js`) decides whether a real message becomes a notification. Two of its gates are
   **off by default** and were silently dropping every real message:
   - `notificationsEnabled` (device-level setting backed by `localStorage
     ["notifications_enabled"]`) defaults to **`false`**; `isEnabled() &&
     displayPopupNotification(...)` never runs.
   - a per-device **`is_silenced`** account-data flag set to `true` on first sync while
     notifications were off (`if (isSilenced(client)) return`) suppresses popups.
   The shipped defaults are overridden for this app:
   - `prelude.js` sets `localStorage["notifications_enabled"] = "true"` on load (only when
     unset, so an explicit user choice wins), and
   - the vendored bundle `8406.js` is patched to drop the `isSilenced(client)` early-return
     inside `displayPopupNotification` (the audio `isSilenced` gate and the UI refresh are
     untouched). A message notifying in the currently-open room while the user has been
     active there (< 2 min) is still suppressed, matching desktop behavior.
1. **`prelude.js`** (injected before the bundle) replaces `window.Notification` with a shim
   that reports `permission === "granted"`, resolves `requestPermission()` with
   `"granted"`, and forwards every `new Notification(title, options)` to the native bridge as
   `window.hosNative.notify(json)`. It also clears the badge on window `focus`.
2. **`NotificationBridge.ets`** (`products/default/src/main/ets/local/`) is exposed to the
   page via the `Web.javaScriptProxy` attribute (`name: 'hosNative'`,
   `asyncMethodList: ['notify', 'clearBadge']`). Its `notify(json)` parses `{title, body,
   tag}`, builds a `notificationManager.NotificationRequest` and publishes it through
   `@kit.NotificationKit`:
   - `slotType: SOCIAL_COMMUNICATION` with an empty `sound` (the in-app sound already plays,
     so the OS notification is silent to avoid doubling it);
   - `badgeNumber` incremented per notification, mirrored with `setBadgeNumber()` for the
     launcher icon;
   - a `wantAgent` targeting `DefaultAbility` (`START_ABILITY`, `CONSTANT_FLAG`) so that
     clicking the notification reopens/focuses the app window;
   - if notifications are disabled, `requestEnableNotification(context)` prompts the user
     exactly once.
   `clearBadge()` resets `setBadgeNumber(0)` when the window regains focus.

Notifications therefore work while the app process is **resident** — including normal use on
the 2-in-1 in close-to-taskbar mode (§7a), where the sync loop keeps running. They do **not**
work when the process is fully terminated; that path would require a Matrix push gateway /
pusher registration plus a background poll or push extension, which is out of scope (§12).

## 8. Permissions

Declared in `products/default/src/main/module.json5`:
- `ohos.permission.INTERNET` — required for the local HTTP server and for the WebView to reach
  Matrix homeservers.
- `ohos.permission.GET_NETWORK_INFO` — network-state visibility.
- `ohos.permission.PREPARE_APP_TERMINATE` — lets the app intercept a close/termination request
  so it can hide to the taskbar instead of exiting (see section 7a).

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
        ├── ets/local/NotificationBridge.ets # Web Notifications API → NotificationKit bridge
        ├── ets/local/RawfileExtractor.ets  # rawfile → sandbox extractor
        ├── ets/defaultability/DefaultAbility.ets
        ├── ets/entryability/EntryAbilityStage.ets  # ability-stage lifecycle (close-to-taskbar)
        ├── module.json5                    # permissions + main ability + ability-stage
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

For device work, the repo ships a one-shot build + sign + deploy + launch wrapper,
`compile_and_run.sh`:

```bash
bash compile_and_run.sh <device-ip>:<port>          # preserves app data (stays logged in)
bash compile_and_run.sh --wipe <device-ip>:<port>   # uninstalls first (clears all data)
```

It reinstalls the HAP **in place** (`install -r`) so the WebView's IndexedDB login/session
survives each deploy; `--wipe` forces a clean install (e.g. for a stale different-signature
install) at the cost of wiping the saved session.

## 11. Rebuilding the element-web bundle

Restage the official **prebuilt release tarball** (recommended, stable build):

```bash
# e.g. element-v1.12.27.tar.gz from https://github.com/element-hq/element-web/releases
RAW=products/default/src/main/resources/rawfile/element
rm -rf "$RAW" && mkdir -p "$RAW"
tar -xzf /path/to/element-v1.12.27.tar.gz -C "$RAW" --strip-components=1
```

Or build from source (Node >= 22 + pnpm):

```bash
cd ../element-web
pnpm install
pnpm exec nx run element-web:prebuild:module_system
pnpm exec nx run element-web:prebuild:rethemendex
pnpm exec nx run element-web:build      # → apps/web/webapp
cp -R apps/web/webapp/* <this-repo>/products/default/src/main/resources/rawfile/element/
```

Then re-apply the project overrides (section 6), the notifier patch + cache-buster
(`scripts/patch-notifier.py`), strip `*.map`, and bump `version`.

## 12. Known limitations & future work

| Area | Status / Note |
|------|---------------|
| DOM / React rendering | Runs in WebView; not native ArkUI components |
| Layout / viewport | Mobile UA forces the phone layout; the ArkWeb viewport scale may need per-device tuning (`layoutMode`, `viewportWidth`, `zoomAccess`) |
| Service workers / PWA | Used over the `http://` origin; offline caching limited by WebView context |
| Voice/video (Element Call) | Bundled; depends on runtime media grants |
| Native integration | Future: bridge native capabilities (share, camera, notifications, biometrics) into element-web via `javaScriptProxy` |
| Close-to-taskbar (2-in-1) | Implemented: window X / dock close hides to taskbar with process alive; reopen via icon (section 7a). To verify on-device: click X and confirm the app re-opens from the taskbar without re-logging in |
| Notifications | Implemented while the app is resident: `prelude.js` shim forwards Web Notifications API calls to a native `NotificationBridge.ets` (NotificationKit publish + launcher badge + click-to-open wantAgent) (section 7b). **Not** available when the process is fully terminated — that would need a Matrix pusher/pushgateway + background polling |

### Recommended follow-ups
1. **Viewport tuning**: experiment with `Web` `layoutMode(WebLayoutMode.FIT_CONTENT)`,
   a `viewport` meta / `viewportWidth`, and `zoomAccess(false)` to make the page fit phones
   and 2-in-1s cleanly.
2. **Signing**: keep `signingConfigs` in `build-profile.json5` current for device deployment.
3. **Native bridge**: expose native HarmonyOS APIs to element-web via `javaScriptProxy`.
4. Trim optional asset groups (e.g. the ~43 MB Element Call widget) to shrink the HAP.
