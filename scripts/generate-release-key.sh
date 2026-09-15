#!/usr/bin/env bash
# generate-release-key.sh — AppGallery release keypair + CSR for element-HOS-PC
#
# Creates the LOCAL release-signing material that AGC needs to issue your
# release certificate and profile. Run this FIRST, before touching AGC.
#
# Files produced in $SIGN_HOME/keytool/:
#   kt-app-release.p12   PRIVATE keystore, alias $ALIAS  — NEVER commit or share
#   kt-app-release.csr   UPLOAD THIS TO AGC FIRST (certificates page)
#
# AGC order (dev ID: 30044000035756399):
#   1. AGC console -> My apps -> create HarmonyOS app
#        bundle-name: com.sys_sec.element
#   2. AGC console -> Certificates -> Add -> upload kt-app-release.csr
#        -> download the issued cert, save as $SIGN_HOME/app-release.cer
#   3. AGC console -> Profiles -> Add (type: RELEASE) for that app + that cert
#        -> download the profile, save as $SIGN_HOME/app-release.p7b
#        (the profile embeds dev ID 30044000035756399 + the release cert)
#   4. ./compile_and_run.sh   (already defaults to the release material)
#
# NOTE: the AGC release profile is bound to a specific bundle-name. If your
# profile says "com.sys_sec.element", the app's bundleName must be exactly that
# (AppScope/app.json5) — a signed HAP will not install under a different bundle.
#
# Passwords are NEVER stored in this repo. Provide them via env or the script
# prompts interactively.
#
# Usage:
#   KEYPW='...' KEYSTOREPW='...' ./scripts/generate-release-key.sh
#   ./scripts/generate-release-key.sh --dry-run     # print resolved params only
#   ./scripts/generate-release-key.sh --force       # overwrite existing p12/csr
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$HOME}"
JW="${JW:-$ROOT/clt/dist/command-line-tools}"
SIGN_HOME="${SIGN_HOME:-$ROOT/signing/Element-PC/harmony}"
HST="$JW/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

log()  { printf '[generate-release-key] %s\n' "$*"; }
die()  { printf '[generate-release-key] FATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- args
DRY_RUN=0
FORCE=0
for _a in "$@"; do
  case "$_a" in
    --dry-run) DRY_RUN=1 ;;
    --force|-f) FORCE=1 ;;
    -*) log "unknown option: $_a"; exit 1 ;;
  esac
done

# ------------------------------------------------------- JDK 17 detection
# Mirrors compile_and_run.sh so both scripts find the same JVM.
JV="${JV:-}"
if [ -z "$JV" ]; then
  for _j in /usr/lib/jvm/java-17-openjdk-17*/ /usr/lib/jvm/java-17-openjdk*/; do
    [ -x "$_j/bin/java" ] && JV="${_j%/}" && break
  done
fi
if [ -z "$JV" ]; then
  JAVA_BIN="$(command -v java || true)"
  [ -n "$JAVA_BIN" ] && JV="$(dirname "$(dirname "$(readlink -f "$JAVA_BIN")")")" || true
fi
[ -n "$JV" ] || die "no JDK 17 found (set JV=/path/to/jdk17)"
[ -x "$JV/bin/java" ] || die "java not found at $JV/bin/java"
[ -f "$HST" ] || die "hap-sign-tool.jar not found: $HST"

# ------------------------------------------------------- release params
ALIAS="${ALIAS:-sys-sec-release}"
KEY_ALG="${KEY_ALG:-ECC}"
KEY_SIZE="${KEY_SIZE:-NIST-P-256}"
SIGN_ALG="${SIGN_ALG:-SHA256withECDSA}"
SUBJECT="${SUBJECT:-C=CN,O=sys_sec,OU=Dev,CN=sys_sec Release}"
KEYSTORE="$SIGN_HOME/keytool/kt-app-release.p12"
CSR="$SIGN_HOME/keytool/kt-app-release.csr"

KEYPW="${KEYPW:-}"
KEYSTOREPW="${KEYSTOREPW:-}"

# ---------------------------------------------------------- passwords
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -z "$KEYPW" ]; then
    read -r -s -p "release key password (KEYPW): " KEYPW; printf '\n'
  fi
  if [ -z "$KEYSTOREPW" ]; then
    read -r -s -p "keystore password (KEYSTOREPW, default = key password): " KEYSTOREPW; printf '\n'
    [ -z "$KEYSTOREPW" ] && KEYSTOREPW="$KEYPW"
  fi
  [ -n "$KEYPW" ] || die "key password empty (set KEYPW or answer the prompt)"
  [ -n "$KEYSTOREPW" ] || die "keystore password empty (set KEYSTOREPW or answer the prompt)"
fi

# ------------------------------------------------------------- dry run
if [ "$DRY_RUN" -eq 1 ]; then
  log "DRY-RUN — resolved parameters:"
  log "  JV          = $JV"
  log "  SIGN_HOME   = $SIGN_HOME"
  log "  ALIAS       = $ALIAS"
  log "  KEY_ALG     = $KEY_ALG / $KEY_SIZE"
  log "  SIGN_ALG    = $SIGN_ALG"
  log "  SUBJECT     = $SUBJECT"
  log "  KEYSTORE    = $KEYSTORE   (${KEYSTOREPW:+password set}${KEYSTOREPW:-password UNSET})"
  log "  CSR         = $CSR"
  [ -f "$KEYSTORE" ] && log "  ! existing keystore present — use --force to overwrite" || true
  [ -f "$CSR" ] && log "  ! existing CSR present — use --force to overwrite" || true
  log "  AGC order: (1) upload this CSR, (2) download app-release.cer,"
  log "             (3) create release profile -> app-release.p7b, (4) compile_and_run.sh"
  exit 0
fi

# --------------------------------------------------------- safety checks
[ -f "$HST" ] || die "hap-sign-tool.jar missing"
if [ -f "$KEYSTORE" ] || [ -f "$CSR" ]; then
  if [ "$FORCE" -ne 1 ]; then
    die "output exists: $KEYSTORE or $CSR — rerun with --force to overwrite (loses the current key!)"
  fi
  log "overwriting existing release material (--force)"
fi
mkdir -p "$(dirname "$KEYSTORE")"

# ------------------------------------------------------- generate keypair
log "generating release keypair -> $KEYSTORE (alias $ALIAS)"
"$JV/bin/java" -jar "$HST" generate-keypair \
  -keyAlias "$ALIAS" \
  -keyPwd "$KEYPW" \
  -keyAlg "$KEY_ALG" \
  -keySize "$KEY_SIZE" \
  -keystoreFile "$KEYSTORE" \
  -keystorePwd "$KEYSTOREPW" 2>&1 | tail -5
[ -f "$KEYSTORE" ] || die "keypair generation failed"

# ------------------------------------------------------------- generate CSR
log "generating release CSR -> $CSR"
"$JV/bin/java" -jar "$HST" generate-csr \
  -keyAlias "$ALIAS" \
  -keyPwd "$KEYPW" \
  -subject "$SUBJECT" \
  -signAlg "$SIGN_ALG" \
  -keystoreFile "$KEYSTORE" \
  -keystorePwd "$KEYSTOREPW" \
  -outFile "$CSR" 2>&1 | tail -5
[ -f "$CSR" ] || die "CSR generation failed"

# --------------------------------------------------------------- validate
log "validating CSR:"
openssl req -in "$CSR" -noout -subject -verify
openssl req -in "$CSR" -noout -text | grep -E "Signature Algorithm|Public Key Algorithm" | head -2

log ""
log "DONE — release material ready."
log "  PRIVATE: $KEYSTORE   (keep this safe, never commit)"
log "  UPLOAD:  $CSR   <- this is the FIRST file to upload to AGC"
log ""
log "NEXT STEPS (AGC, dev ID 30044000035756399):"
log "  1. AGC -> My apps -> create HarmonyOS app, bundle com.sys_sec.element"
log "  2. AGC -> Certificates -> Add -> upload $CSR"
log "       download cert -> save as $SIGN_HOME/app-release.cer"
log "  3. AGC -> Profiles -> Add (type RELEASE) for that app + cert"
log "       download profile -> save as $SIGN_HOME/app-release.p7b"
log "  4. run ./compile_and_run.sh (signs the HAP with the release material)"
