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

// Auto-enable element-web's device-level notifications ("notifications_enabled",
// default false) so the Notifier actually runs on this HOS app and real messages
// reach the shim below. Only set it when the user hasn't chosen otherwise.
try {
    if (typeof localStorage !== "undefined" && localStorage.getItem("notifications_enabled") === null) {
        localStorage.setItem("notifications_enabled", "true");
    }
} catch (e) { /* ignore */ }
try {
    if (typeof console !== "undefined" && console.log) {
        console.log("HOS-NOTIF boot notifications_enabled=" + localStorage.getItem("notifications_enabled"));
    }
} catch (e) { /* ignore */ }

// Notifications bridge.
//
// element-web shows desktop notifications via the Web Notifications API, which
// ArkWeb silently drops. Replace window.Notification with a shim that reports
// "granted" and forwards every notification to the native HarmonyOS bridge
// (window.hosNative.notify -> NotificationBridge -> NotificationKit), so
// notifications and the launcher badge reach the OS while the app is resident.
(function () {
    var hasShim = false;
    try {
        hasShim = "HOSNotificationShim" in window;
    } catch (e) { /* ignore */ }
    if (hasShim) {
        return;
    }
    function notify(title, options) {
        try {
            if (window.hosNative && window.hosNative.notify) {
                var payload = {
                    title: title || "Element",
                    body: (options && options.body) || "",
                    tag: (options && options.tag) || ""
                };
                window.hosNative.notify(JSON.stringify(payload));
            }
        } catch (e) {
            // ignore bridge errors; element-web must keep running
        }
    }
    function HostNotification(title, options) {
        this.title = title || "";
        this.body = (options && options.body) || "";
        this.tag = (options && options.tag) || "";
        this.silent = Boolean(options && options.silent);
        this.onclick = null;
        this.onclose = null;
        this.onshow = null;
        this.onerror = null;
        var self = this;
        notify(this.title, { body: this.body, tag: this.tag });
        setTimeout(function () {
            if (self.onshow) {
                try { self.onshow.apply(self, []); } catch (e) { /* ignore */ }
            }
        }, 0);
    }
    HostNotification.close = function () { /* no-op */ };
    HostNotification.prototype.close = function () {
        this.onclick = null;
        if (this.onclose) {
            try { this.onclose.apply(this, []); } catch (e) { /* ignore */ }
        }
    };
    try {
        Object.defineProperty(HostNotification, "permission", {
            get: function () { return "granted"; },
            enumerable: true,
            configurable: true
        });
        Object.defineProperty(HostNotification.prototype, "permission", {
            get: function () { return "granted"; },
            enumerable: true,
            configurable: true
        });
    } catch (e) { /* ignore */ }
    HostNotification.requestPermission = function (cb) {
        if (typeof cb === "function") {
            try { cb("granted"); } catch (e) { /* ignore */ }
        }
        return Promise.resolve("granted");
    };
    HostNotification.maxActions = 0;
    try {
        window.Notification = HostNotification;
    } catch (e) { /* ignore */ }
    try {
        window.HOSNotificationShim = true;
    } catch (e) { /* ignore */ }
    // Clear the launcher badge when the app window regains focus.
    window.addEventListener("focus", function () {
        try {
            if (window.hosNative && window.hosNative.clearBadge) {
                window.hosNative.clearBadge();
            }
        } catch (e) { /* ignore */ }
    });
}());
