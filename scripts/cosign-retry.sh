#!/usr/bin/env bash
# =============================================================================
# BAOBAB Enterprise Platform — Bounded Retry Wrapper for Cosign Calls
# =============================================================================
# File: scripts/cosign-retry.sh
#
# Retries a single cosign invocation (sign / attest / any subcommand) with
# exponential backoff + jitter, then fails loudly if every attempt is
# exhausted. Exists because cosign's uploads to the public Rekor
# transparency log occasionally hit transient outages — cosign already
# retries internally (4 attempts, observed live in this project's own CI)
# before giving up, but a longer blip can still exceed that. This wraps the
# WHOLE cosign invocation in a further bounded retry rather than failing an
# entire release on a momentary network hiccup.
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
# CHANGE (2026-08-23): the final error message no longer asserts "this is
# most likely a transient outage." Two real incidents since the change
# above both LOOKED like Rekor connectivity failures from this wrapper's
# vantage point but were NOT transient outages: (1) an oversized SBOM
# attestation payload being rejected by Rekor v1 on every single attempt,
# and (2) an "unknown flag" error from a cosign-installer/cosign-CLI
# version mismatch, which this wrapper still dutifully retried 5 times
# before failing. This wrapper cannot distinguish "genuinely transient" from
# "deterministic, every time, for a structural reason" — retrying is still
# the right default behavior either way, but presupposing the diagnosis in
# the failure message actively steered debugging in the wrong direction
# both times. It now lists what to check instead of guessing.
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
# Deliberately NOT asserting a single most-likely cause (see CHANGE
# 2026-08-23 above) — a failure that survives every retry is just as
# consistent with a deterministic, non-network cause as with an outage.
echo "::error:: Every attempt failed identically, which usually means a deterministic cause, not random network flakiness. Before re-running, check in order:"
echo "::error::   1. Is the error itself something other than a connection/timeout? (e.g. 'unknown flag', a size/quota rejection, an auth error) — read the actual error text above, not just this summary."
echo "::error::   2. https://status.sigstore.dev — rule out a genuine, currently-reported Rekor/Fulcio outage."
echo "::error::   3. Did the cosign version actually installed this run change? ('cosign version' in an earlier step's log) — an installer/CLI version mismatch can silently swap flag support."
echo "::error::   4. Payload size — an oversized SBOM/provenance predicate can be rejected deterministically on every attempt; see the SBOM-size diagnostic step in publish.yml if this is the SBOM attest call."
exit 1