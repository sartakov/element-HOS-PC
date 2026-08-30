// Element for HarmonyOS prelude.
// Runs before element-web's bundle.js. The WebView presents a mobile (Android)
// user agent so element-web renders its phone layout. Set the session flag that
// tells element-web not to auto-redirect to its native-app download page
// (mobile_guide/), because this app IS the Element client.
try {
    sessionStorage.setItem("skip_mobile_redirect", "true");
} catch (e) {
    // sessionStorage unavailable; redirect may occur (acceptable fallback)
}
