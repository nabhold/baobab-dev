#!/usr/bin/env bash
# =============================================================================
# BAOBAB Enterprise Platform — Bounded Retry Wrapper for Cosign Calls
# =============================================================================
# File: scripts/cosign-retry.sh
#
# Purpose:
#   Retries a single cosign invocation (sign / attest / any subcommand) a
#   bounded number of times with a fixed delay between attempts, then fails
#   loudly if every attempt is exhausted. Exists because cosign's uploads to
#   the public Rekor transparency log (rekor.sigstore.dev) occasionally hit
#   transient outages — cosign already retries internally (4 attempts,
#   observed live in this project's own CI) before giving up, but a longer
#   blip can still exceed that. This wraps the WHOLE cosign invocation in a
#   further bounded retry rather than failing an entire release on a
#   momentary network hiccup.
#
#   COSIGN_RETRY_COUNT / COSIGN_RETRY_DELAY are NOT real cosign flags or
#   environment variables (verified against cosign's own CLI/source before
#   this script was written) — retry logic has to live outside cosign, here.
#
# Usage:
#   scripts/cosign-retry.sh <cosign command and arguments...>
#
#   Example:
#     scripts/cosign-retry.sh cosign attest --yes \
#       --type spdxjson --predicate sbom-amd64.json \
#       ghcr.io/nabhold/baobab-dev@sha256:...
#
# Configuration (optional, via environment):
#   COSIGN_RETRY_ATTEMPTS   Number of attempts before giving up. Default: 3.
#   COSIGN_RETRY_DELAY      Seconds to sleep between attempts. Default: 20.
#
# Exit codes:
#   0 = the wrapped command eventually succeeded
#   1 = the wrapped command failed on every attempt, or no command was given
# =============================================================================

set -Eeuo pipefail

ATTEMPTS="${COSIGN_RETRY_ATTEMPTS:-3}"
DELAY="${COSIGN_RETRY_DELAY:-20}"

if [[ $# -eq 0 ]]; then
    echo "::error:: scripts/cosign-retry.sh: no command given." >&2
    echo "Usage: scripts/cosign-retry.sh <cosign command and arguments...>" >&2
    exit 1
fi

# Human-readable label for log messages. Safe to print verbatim — every
# call site in this project passes only image digests and predicate file
# paths, never secrets.
LABEL="$*"

for attempt in $(seq 1 "${ATTEMPTS}"); do
    # Tested as an `if` condition, so a failing "$@" does not trip `set -e`
    # here — the loop is allowed to continue and retry.
    if "$@"; then
        exit 0
    fi

    echo "::warning:: cosign-retry: attempt ${attempt}/${ATTEMPTS} failed for: ${LABEL}"

    if [[ "${attempt}" -lt "${ATTEMPTS}" ]]; then
        sleep "${DELAY}"
    fi
done

echo "::error:: cosign-retry: all ${ATTEMPTS} attempts failed for: ${LABEL}"
echo "::error:: This is most likely a transient rekor.sigstore.dev outage — check https://status.sigstore.dev before re-running."
exit 1