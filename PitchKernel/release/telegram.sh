#!/usr/bin/env bash

# ======================================================
# PitchKernel — TELEGRAM ARTIFACT DELIVERY
# Adapted from LuminaireProtocol/telegram.sh
# Source this script after build; requires env vars:
#   ZIP_PATH, ZIP_NAME, KERNEL_VERSION
#   ROOT_SOLUTION (RESUKISU|VANILLA)
#   SUSFS_ENABLED (true|false)
#   KERNEL_SRC, KERNEL_BRANCH, COMPILER_STRING
# ======================================================

TELEGRAM_API_TIMEOUT="${TELEGRAM_API_TIMEOUT:-60}"
TELEGRAM_MAX_RETRIES="${TELEGRAM_MAX_RETRIES:-3}"
TELEGRAM_MAX_FILE_BYTES=$(( 50 * 1024 * 1024 ))
TELEGRAM_CAPTION_LIMIT=1024

log()  { echo "[TG] $*"; }
warn() { echo "[TG] WARNING: $*"; }

[ -z "${TELEGRAM_BOT_TOKEN:-}" ]          && warn "TELEGRAM_BOT_TOKEN not set"          && return 0
[ -z "${TELEGRAM_CHAT_ID:-}" ]            && warn "TELEGRAM_CHAT_ID not set"             && return 0
[ -z "${TELEGRAM_THREAD_ID_ARTIFACT:-}" ] && warn "TELEGRAM_THREAD_ID_ARTIFACT not set"  && return 0
[ ! -f "${ZIP_PATH:-}" ]                  && warn "ZIP_PATH not set or missing"           && return 0

ZIP_SIZE_BYTES=$(stat -c%s "$ZIP_PATH" 2>/dev/null || stat -f%z "$ZIP_PATH" 2>/dev/null || echo 0)
[ "$ZIP_SIZE_BYTES" -eq 0 ] && warn "Cannot determine zip size" && return 0
if [ "$ZIP_SIZE_BYTES" -gt "$TELEGRAM_MAX_FILE_BYTES" ]; then
    ZIP_SIZE_MB=$(( ZIP_SIZE_BYTES / 1024 / 1024 ))
    warn "${ZIP_NAME} is ${ZIP_SIZE_MB}MB — exceeds Telegram 50MB limit, sending link only"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        -d "message_thread_id=${TELEGRAM_THREAD_ID_ARTIFACT}" \
        -d "parse_mode=HTML" \
        --data-urlencode "text=<b>PitchKernel</b> build ready — zip too large for direct upload (${ZIP_SIZE_MB}MB). Download from CI artifacts."
    return 0
fi

case "${ROOT_SOLUTION:-VANILLA}" in
    RESUKISU) ROOT_DISPLAY="ReSukiSU" ;;
    SUKISU)   ROOT_DISPLAY="SukiSU"   ;;
    VANILLA)  ROOT_DISPLAY="Vanilla"  ;;
    *)        ROOT_DISPLAY="${ROOT_SOLUTION}" ;;
esac

SUSFS_VER="N/A"
if [ "${SUSFS_ENABLED:-false}" = "true" ] && [ "${ROOT_SOLUTION:-}" != "VANILLA" ]; then
    SUSFS_H="${KERNEL_SRC:-}/include/linux/susfs.h"
    if [ -f "$SUSFS_H" ]; then
        SUSFS_VER=$(grep -m1 'SUSFS_VERSION' "$SUSFS_H" | grep -oP 'v?\d+\.\d+\.\d+' | head -1 || true)
        [ -n "$SUSFS_VER" ] && [[ "$SUSFS_VER" != v* ]] && SUSFS_VER="v${SUSFS_VER}"
        [ -z "$SUSFS_VER" ] && SUSFS_VER="N/A"
    fi
fi

mdv2_code_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

CAPTION="\`\`\`PitchKernel
Device    : munch (Poco F4)
Linux     : $(mdv2_code_escape "${KERNEL_VERSION:-N/A}")
Root      : $(mdv2_code_escape "$ROOT_DISPLAY")
SuSFS     : $(mdv2_code_escape "$SUSFS_VER")
Branch    : $(mdv2_code_escape "${KERNEL_BRANCH:-N/A}")
Compiler  : $(mdv2_code_escape "${COMPILER_STRING:-ZyCromerZ Clang 16}")
Date      : $(date +'%d %b %Y')
\`\`\`"

CAPTION_LEN=$(printf '%s' "$CAPTION" | wc -m)
if [ "$CAPTION_LEN" -gt "$TELEGRAM_CAPTION_LIMIT" ]; then
    warn "Caption ${CAPTION_LEN} chars — truncating"
    SUFFIX=$'\n...\n```'
    KEEP=$(( TELEGRAM_CAPTION_LIMIT - ${#SUFFIX} ))
    CAPTION="$(printf '%s' "$CAPTION" | head -c "$KEEP")${SUFFIX}"
fi

ATTEMPT=1
SEND_OK=0

while [ "$ATTEMPT" -le "$TELEGRAM_MAX_RETRIES" ]; do
    log "Sending ${ZIP_NAME} (attempt ${ATTEMPT}/${TELEGRAM_MAX_RETRIES})..."

    HTTP_CODE=$(curl -s -o /tmp/tg_response.json -w "%{http_code}" \
        --max-time "$TELEGRAM_API_TIMEOUT" \
        -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \
        -F "chat_id=${TELEGRAM_CHAT_ID}" \
        -F "message_thread_id=${TELEGRAM_THREAD_ID_ARTIFACT}" \
        -F "parse_mode=MarkdownV2" \
        -F "document=@${ZIP_PATH};filename=${ZIP_NAME}" \
        -F "caption=${CAPTION}" 2>/tmp/tg_curl_err.log) || HTTP_CODE="000"

    RESPONSE=$(cat /tmp/tg_response.json 2>/dev/null || echo "")
    CURL_ERR=$(cat /tmp/tg_curl_err.log 2>/dev/null || echo "")

    if [ "$HTTP_CODE" = "200" ] && echo "$RESPONSE" | grep -q '"ok":true'; then
        log "Artifact sent to Telegram ✅"
        SEND_OK=1
        break
    fi

    case "$HTTP_CODE" in
        000)   warn "Connection/timeout (${CURL_ERR:-no details}) — retrying" ;;
        429|5*) warn "HTTP ${HTTP_CODE} transient — retrying. Response: ${RESPONSE}" ;;
        *)     warn "HTTP ${HTTP_CODE} non-retryable. Response: ${RESPONSE}"; break ;;
    esac

    if [ "$ATTEMPT" -lt "$TELEGRAM_MAX_RETRIES" ]; then
        SLEEP_SECS=$(( 2 ** ATTEMPT ))
        log "Retrying in ${SLEEP_SECS}s..."
        sleep "$SLEEP_SECS"
    fi
    ATTEMPT=$(( ATTEMPT + 1 ))
done

[ "$SEND_OK" -ne 1 ] && log "Telegram delivery failed after ${TELEGRAM_MAX_RETRIES} attempts. Artifact still in CI."

rm -f /tmp/tg_response.json /tmp/tg_curl_err.log
return 0

