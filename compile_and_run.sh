#!/usr/bin/env bash
# compile_and_run.sh — build + AGC-sign for head-less mode
#
# Usage:
#   MODE=debug|release ./compile_and_run.sh [--wipe] [TARGET]
#
#   MODE    signing mode (default: debug)
#             debug   -> app-debug.cer/p7b + kt-app.p12, then hdc install + launch
#             release -> assembleApp + app-release.cer/p7b + kt-app-release.p12, sign the
#                        .app package only (store upload; release .app cannot be sideloaded,
#                        error 9568322)
#   --wipe  uninstall the app first, clearing all app data incl. the login
#           session (by default app data is preserved across reinstalls)
#
# Overridable environment variables:
#   ROOT            base dir; everything below derives from it (default: $HOME)
#   TARGET          hdc target (same as the positional argument, default: DEVICE_IP:PORT)
#   BUNDLE          app bundle name to launch  (default: com.sys_sec.element)
#   PROJECT_TOP     app project root           (default: dir of this script)
#   SIGN_HOME       AGC signing material dir   (default: $ROOT/signing/Element-PC/harmony)
#   MODE            signing mode (debug|release, default: debug)
#   APPCERT         app certificate            (default: $SIGN_HOME/app-<mode>.cer)
#   PROFILE         provisioning profile       (default: $SIGN_HOME/app-<mode>.p7b)
#   P12             signing keystore            (default: debug: kt-app.p12 / release: kt-app-release.p12)
#   ALIAS           keystore key alias         (default: debug: underleaf-app / release: sys-sec-release)
#   KEYPW           keystore/key password      (prompted if unset; never stored)
#   HWG             path to `hvigorw`          (default: $ROOT/clt/dist/command-line-tools/bin/hvigorw)
#   HDC             path to `hdc`              (default: <bundle>/sdk/default/openharmony/toolchains/hdc)
#   JV              JAVA_HOME for keytool/java (default: openEuler JDK17 path if present, else `java` on PATH)
#   NODE_HOME       node home for hvigor       (default: <bundle>/tool/node)
#   PATCH           dir with the hap-sign-tool log4j patch (default: /tmp/opencode/signing/patch)
set -u

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_TOP="${PROJECT_TOP:-$SCRIPT_DIR}"
TARGET="${TARGET:-DEVICE_IP:PORT}"
WIPE=0
_POSARGS=()
for _a in "$@"; do
  case "$_a" in
    --wipe|-w) WIPE=1 ;;
    -*) log "unknown option: $_a"; exit 1 ;;
    *) _POSARGS+=("$_a") ;;
  esac
done
[ "${#_POSARGS[@]}" -gt 0 ] && TARGET="${_POSARGS[0]}"
BUNDLE="${BUNDLE:-com.sys_sec.element}"
ROOT="${ROOT:-$HOME}"
SIGN_HOME="${SIGN_HOME:-$ROOT/signing/Element-PC/harmony}"
MODE="${MODE:-debug}"
case "$MODE" in
  debug|release) ;;
  *) log "FATAL: MODE must be debug or release (got '$MODE')"; exit 1 ;;
esac
JW="${JW:-$ROOT/clt/dist/command-line-tools}"
if [ -z "${JV:-}" ]; then
  for _j in /usr/lib/jvm/java-17-openjdk-17*/ /usr/lib/jvm/java-17-openjdk*/; do
    [ -x "$_j/bin/java" ] && JV="${_j%/}" && break
  done
  if [ -z "$JV" ]; then
    JAVA_BIN="$(command -v java || true)"
    [ -n "$JAVA_BIN" ] && JV="$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")" || JV=""
  fi
fi
[ -n "$JV" ] || { log "FATAL: no JDK found (set JV to a JDK 17 home)"; exit 1; }
HWG="${HWG:-$JW/bin/hvigorw}"
HDC="${HDC:-$JW/sdk/default/openharmony/toolchains/hdc}"
NODE_HOME="${NODE_HOME:-$JW/tool/node}"
PATCH="${PATCH:-/tmp/opencode/signing/patch}"
HST="$JW/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

export JAVA_HOME="$JV"
export NODE_HOME="$NODE_HOME"
export PATH="$NODE_HOME/bin:$JV/bin:$PATH"

# Signing material by MODE. Each value is env-overridable.
#   debug:   AGC debug cert/profile for $BUNDLE + shared dev keytool
#            (reissue the debug profile in AGC for bundle $BUNDLE, save app-debug.cer/p7b)
#   release: AGC release cert/profile + local release keytool (generate-release-key.sh)
if [ "$MODE" = "release" ]; then
  APPCERT="${APPCERT:-$SIGN_HOME/app-release.cer}"
  PROFILE="${PROFILE:-$SIGN_HOME/app-release.p7b}"
  P12="${P12:-$SIGN_HOME/keytool/kt-app-release.p12}"
  ALIAS="${ALIAS:-sys-sec-release}"
  KEYPW="${KEYPW:-}"
  if [ -z "$KEYPW" ]; then
    read -r -s -p "release key password (KEYPW): " KEYPW; printf '\n'
  fi
  [ -n "$KEYPW" ] || { log "FATAL: release KEYPW empty"; exit 1; }
  SIGNED="$SIGN_HOME/Element-PC-release-signed.app"
else
  APPCERT="${APPCERT:-$SIGN_HOME/app-debug.cer}"
  PROFILE="${PROFILE:-$SIGN_HOME/app-debug.p7b}"
  P12="${P12:-$SIGN_HOME/keytool/kt-app.p12}"
  ALIAS="${ALIAS:-underleaf-app}"
  KEYPW="${KEYPW:-}"
  if [ -z "$KEYPW" ]; then
    read -r -s -p "debug key password (KEYPW): " KEYPW; printf '\n'
  fi
  [ -n "$KEYPW" ] || { log "FATAL: debug KEYPW empty"; exit 1; }
  SIGNED="$SIGN_HOME/Element-PC-debug-signed.hap"
fi

if [ ! -f "$P12" ] || [ ! -f "$APPCERT" ] || [ ! -f "$PROFILE" ]; then
  log "FATAL: $MODE signing material incomplete."
  log "  debug:   issue an AGC debug cert + profile for bundle $BUNDLE,"
  log "           save as $APPCERT and $PROFILE"
  log "  release: run scripts/generate-release-key.sh, upload the CSR at AGC,"
  log "           save the issued files as $APPCERT and $PROFILE"
  log "           (and $P12 must exist)"
  exit 1
fi

HST_CP="$(dirname "$HST")"
HST_DIR="${HST_CP%/*}/hapsigntool-unzip"
if [ ! -f "$PATCH/WebApp.class" ]; then
  log "FATAL: missing log4j patch $PATCH/WebApp.class (see REPRODUCE_GUIDE §2.7 patch step)"
  exit 1
fi
CP="-Duser.language=en -Duser.country=US -Djava.locale.providers=CLDR -Duser.timezone=UTC \
    -cp $PATCH:$HST com.ohos.hapsigntool.HapSignTool"

# ------------------------------------------------------------------ build
cd "$PROJECT_TOP" || { log "FATAL: cannot cd $PROJECT_TOP"; exit 1; }
log "building in $PROJECT_TOP (mode=$MODE) ..."
"$HWG" --stop-daemon >/dev/null 2>&1
if [ "$MODE" = "release" ]; then
  "$HWG" assembleApp --mode project -p product=default --no-daemon >/tmp/opencode/build.log 2>&1
else
  "$HWG" assembleHap --mode module -p product=default -p module=default@default --no-daemon >/tmp/opencode/build.log 2>&1
fi
if ! grep -q 'BUILD SUCCESSFUL' /tmp/opencode/build.log; then
  log "FATAL: build failed (see /tmp/opencode/build.log)"; tail -20 /tmp/opencode/build.log >&2; exit 1
fi
log "build OK"

if [ "$MODE" = "release" ]; then
  OUT=$(ls -t "$PROJECT_TOP"/build/outputs/default/*-unsigned.app 2>/dev/null | head -1)
  IN_FORM="zip"
  [ -n "$OUT" ] || { log "FATAL: no *-unsigned.app in build/outputs/default"; exit 1; }
else
  OUT=$(ls -t "$PROJECT_TOP"/products/default/build/default/outputs/default/*default-default-unsigned.hap 2>/dev/null | head -1)
  IN_FORM=""
  [ -n "$OUT" ] || { log "FATAL: no *-unsigned.hap in build outputs"; exit 1; }
fi
log "input : $OUT"
log "mode  : $MODE"
log "target: $TARGET"

# ------------------------------------------------------------------ sign
sign() {
  local args="-keyAlias $ALIAS -keyPwd $KEYPW -signAlg SHA256withECDSA -mode localSign \
    -appCertFile $APPCERT -profileFile $PROFILE -inFile $OUT -keystoreFile $P12 -keystorePwd $KEYPW \
    -outFile $SIGNED"
  [ -n "$IN_FORM" ] && args="$args -inForm $IN_FORM"
  "$JV/bin/java" $CP sign-app $args 2>&1
}

OUTPUT=$(sign)
if echo "$OUTPUT" | grep -q 'The certificate has expired'; then
  NB=$(echo "$OUTPUT" | sed -n 's/.*NotBefore: \(.*\)$/\1/p' | head -1)
  [ -n "$NB" ] || { log "FATAL: cert-time error but could not parse NotBefore"; echo "$OUTPUT" >&2; exit 1; }
  SHIFT=$(date -u -d "$NB + 10 minutes" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  if [ -z "$SHIFT" ] || ! sudo -n true 2>/dev/null; then
    log "FATAL: host clock is outside the AGC cert validity and we cannot shift it (need passwordless sudo)"
    echo "$OUTPUT" >&2; exit 1
  fi
  log "host clock outside cert validity; temporarily setting clock to $SHIFT UTC"
  T0=$(date +'%F %T %z')
  sudo date -u -s "$SHIFT" >/dev/null
  trap 'sudo date -s "$T0" >/dev/null 2>&1; log "clock restored to $T0"' EXIT
  OUTPUT=$(sign)
fi
echo "$OUTPUT" | grep -Eq 'Sign Hap success|sign-app success' \
  || { log "FATAL: sign-app failed"; echo "$OUTPUT" >&2; exit 1; }
log "sign OK"

# ------------------------------------------------------------------ verify
"$JV/bin/java" $CP verify-app -inFile "$SIGNED" -outCertChain /tmp/vcc.cer -outProfile /tmp/vp.p7b \
  >/tmp/opencode/verify.log 2>&1
grep -q 'verify: Verify success' /tmp/opencode/verify.log \
  || { log "FATAL: verify-app failed (see /tmp/opencode/verify.log)"; cat /tmp/opencode/verify.log >&2; exit 1; }
log "verify OK"

# ------------------------------------------------------------------ release: stop here
if [ "$MODE" = "release" ]; then
  log "DONE (release mode) — signed .app package ready for store upload:"
  log "  $SIGNED"
  log "  Release-signed .app cannot be sideloaded (error 9568322);"
  log "  upload $SIGNED to AppGallery Connect."
  exit 0
fi

# ------------------------------------------------------------------ install / run
log "connecting to $TARGET ..."
CONNECTED=0
for i in 1 2 3 4 5; do
  "$HDC" kill >/dev/null 2>&1          # restart local hdc server each attempt
  sleep 1
  "$HDC" tconn "$TARGET" >/dev/null 2>&1
  sleep 2
  if "$HDC" list targets -v 2>/dev/null | grep -iE "^${TARGET}[[:space:]]" | grep -qE '(Connected|UseNormal)'; then
    CONNECTED=1
    break
  fi
  log "  attempt $i: target not Connected yet"
done
if [ "$CONNECTED" -ne 1 ]; then
  log "FATAL: no connected target at $TARGET  (is the device reachable / dialog accepted?)"
  "$HDC" list targets 2>&1
  exit 1
fi
log "connected"

# install -r keeps app data (WebView IndexedDB -> login session must survive restarts).
# Only fall back to a full uninstall+reinstall when the in-place upgrade fails
# (e.g. stale different-signature install, 9568332). --wipe forces the old behaviour.
if [ "$WIPE" -eq 1 ]; then
  log "wipe requested: uninstalling $BUNDLE first (app data will be cleared)"
  "$HDC" shell bm uninstall -n "$BUNDLE" >/dev/null 2>&1
fi
if "$HDC" install -r "$SIGNED" 2>&1 | tee /tmp/opencode/install.log | grep -q 'install bundle successfully'; then
  log "install OK (data preserved)"
else
  log "in-place install failed, retrying after uninstall (this wipes app data)"
  "$HDC" shell bm uninstall -n "$BUNDLE" >/dev/null 2>&1
  if ! "$HDC" install -r "$SIGNED" 2>&1 | tee /tmp/opencode/install.log | grep -q 'install bundle successfully'; then
    log "FATAL: install failed"
    cat /tmp/opencode/install.log >&2
    exit 1
  fi
  log "install OK (after uninstall)"
fi
"$HDC" shell aa start -a DefaultAbility -b "$BUNDLE"
log "DONE — app launched on $TARGET"