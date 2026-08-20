#!/usr/bin/env bash
# =============================================================================
# BAOBAB Enterprise Platform — Bounded Retry Wrapper for Cosign Calls
# =============================================================================
# File: scripts/cosign-retry.sh
#
# Retries a single cosign invocation (sign / attest / any subcommand) with
# exponential backoff + jitter, then fails loudly if every attempt is
# exhausted. Exists because cosign's uploads to the public Rekor
# transparency log (rekor.sigstore.dev) occasionally hit transient outages
# — cosign already retries internally (4 attempts, observed live in this
# project's own CI) before giving up, but a longer blip can still exceed
# that. This wraps the WHOLE cosign invocation in a further bounded retry
# rather than failing an entire release on a momentary network hiccup.
#
# COSIGN_RETRY_* are NOT real cosign flags or environment variables
# (verified against cosign's own CLI/source) — retry logic has to live
# outside cosign, here.
#
# CHANGE (2026-08-20): a live release run (v1.0.0-rc.2) exhausted the old
# fixed 3 attempts / 20s delay (~100s total budget, incl. cosign's own
# internal retries) against a genuine rekor.sigstore.dev outage — see
# publish_logs.rtf. Fixed, short delays give a real outage almost no room
# to clear. Replaced with capped exponential backoff (equal jitter, per
# the AWS "Exponential Backoff and Jitter" pattern) and a longer default
# attempt count, trading a few extra minutes of a tag-gated release job
# (not on the PR hot path) for a real chance of riding out a blip instead
# of forcing a manual re-run every time.
#
# Usage:
#   scripts/cosign-retry.sh <cosign command and arguments...>
#
# Configuration (optional, via environment):
#   COSIGN_RETRY_ATTEMPTS    Attempts before giving up. Default: 5.
#   COSIGN_RETRY_BASE_DELAY  Seconds, backoff base (doubles each attempt).
#                            Default: 15.
#   COSIGN_RETRY_MAX_DELAY   Seconds, cap on any single delay. Default: 120.
#
# Exit codes:
#   0 = the wrapped command eventually succeeded
#   1 = the wrapped command failed on every attempt, or no command was given
# =============================================================================

set -Eeuo pipefail

ATTEMPTS="${COSIGN_RETRY_ATTEMPTS:-5}"
BASE_DELAY="${COSIGN_RETRY_BASE_DELAY:-15}"
MAX_DELAY="${COSIGN_RETRY_MAX_DELAY:-120}"

if [[ $# -eq 0 ]]; then
    echo "::error:: scripts/cosign-retry.sh: no command given." >&2
    echo "Usage: scripts/cosign-retry.sh <cosign command and arguments...>" >&2
    exit 1
fi

# Human-readable label for log messages. Safe to print verbatim — every
# call site in this project passes only image digests and predicate file
# paths, never secrets.
LABEL="$*"

# Capped exponential backoff with "equal jitter" (half fixed, half random):
# guarantees a real minimum wait every attempt while still avoiding
# synchronized retries against Rekor. delay = min(BASE * 2^(n-1), MAX).
backoff_sleep() {
    local attempt="$1" delay half jitter sleep_time
    delay=$(( BASE_DELAY * (1 << (attempt - 1)) ))
    (( delay > MAX_DELAY )) && delay="${MAX_DELAY}"
    half=$(( delay / 2 ))
    jitter=$(( RANDOM % (half + 1) ))
    sleep_time=$(( half + jitter ))
    echo "::notice:: cosign-retry: waiting ${sleep_time}s before attempt $((attempt + 1))/${ATTEMPTS}."
    sleep "${sleep_time}"
}

for attempt in $(seq 1 "${ATTEMPTS}"); do
    # Tested as an `if` condition, so a failing "$@" does not trip `set -e`
    # here — the loop is allowed to continue and retry.
    if "$@"; then
        exit 0
    fi

    echo "::warning:: cosign-retry: attempt ${attempt}/${ATTEMPTS} failed for: ${LABEL}"

    if [[ "${attempt}" -lt "${ATTEMPTS}" ]]; then
        backoff_sleep "${attempt}"
    fi
done

echo "::error:: cosign-retry: all ${ATTEMPTS} attempts failed for: ${LABEL}"
echo "::error:: This is most likely a transient rekor.sigstore.dev outage — check https://status.sigstore.dev before re-running."
exit 1