#!/usr/bin/env bash
# =============================================================================
# BAOBAB Enterprise Platform — Complete Multi-Arch OCI Index Fetcher
# =============================================================================
# File: scripts/fetch-complete-oci-index.sh
#
# Fetches a merged multi-arch OCI index via `crane manifest` and retries
# with capped exponential backoff (equal jitter — same algorithm as
# cosign-retry.sh's backoff_sleep) until BOTH linux/amd64 and linux/arm64
# have an image-manifest AND a sibling attestation-manifest present,
# matched via the `vnd.docker.reference.type` / `vnd.docker.reference.digest`
# annotations `crane index append --flatten` writes during the manifest
# merge in publish.yml's "Publish multi-architecture OCI manifest" step.
#
# EXTRACTED (2026-08-28) from publish.yml's "Extract per-platform SLSA
# provenance predicates" and "Extract per-platform SPDX SBOM predicates"
# steps, which duplicated this exact retry-and-verify loop verbatim. Both
# steps read the same merged index and can fail the same way for the same
# reasons: a genuine GHCR read-after-write propagation delay under
# concurrent multi-target publishing, or a real gap upstream in what the
# `build` job produced for a given platform (see the optional third
# argument below — the caller supplies which upstream step to point at,
# since that differs between provenance and SBOM).
#
# Deliberately does NOT go further and also extract the per-platform
# attestation-digest lookup that both callers perform on the JSON this
# script returns — that lookup is a couple of lines of `jq`, already
# trivial, and each caller's error messages diverge slightly (provenance
# points at the SBOM/provenance build step by name; SBOM does not). The
# genuinely complex, failure-prone part — the retry loop and completeness
# check — is what's shared here.
#
# Prints the complete, verified manifest JSON to stdout on success. Emits
# ::warning::/::error:: annotations directly to stderr (this only ever
# runs inside a GitHub Actions step) and exits non-zero if every attempt
# is exhausted — callers must not attempt to parse a partial result.
#
# Usage:
#   scripts/fetch-complete-oci-index.sh <image-ref-without-digest> <digest> [hint]
#
#   <image-ref-without-digest>  e.g. ghcr.io/nabhold/baobab-dev
#   <digest>                    e.g. sha256:abc123... (the merged index's own digest)
#   [hint]                      Optional. Appended to the final error message,
#                                naming the specific upstream `build`-job step
#                                most likely responsible if this is a genuine
#                                gap rather than propagation delay. Defaults to
#                                a generic pointer.
#
# Configuration (optional, via environment):
#   MANIFEST_RETRY_ATTEMPTS    Attempts before giving up. Default: 5.
#   MANIFEST_RETRY_BASE_DELAY  Seconds, backoff base (doubles each attempt).
#                              Default: 10.
#   MANIFEST_RETRY_MAX_DELAY   Seconds, cap on any single delay. Default: 60.
#
# Exit codes:
#   0 = a complete manifest was fetched; JSON printed to stdout
#   1 = all attempts exhausted, or required arguments missing
# =============================================================================

set -Eeuo pipefail

IMG="${1:-}"
DIGEST="${2:-}"
HINT="${3:-the build job step that produced this leg}"

if [[ -z "${IMG}" || -z "${DIGEST}" ]]; then
  echo "::error:: scripts/fetch-complete-oci-index.sh: usage: fetch-complete-oci-index.sh <image-ref> <digest> [hint]" >&2
  exit 1
fi

ATTEMPTS="${MANIFEST_RETRY_ATTEMPTS:-5}"
BASE_DELAY="${MANIFEST_RETRY_BASE_DELAY:-10}"
MAX_DELAY="${MANIFEST_RETRY_MAX_DELAY:-60}"

# Capped exponential backoff with "equal jitter" (half fixed, half
# random) — same algorithm as cosign-retry.sh's backoff_sleep, duplicated
# here rather than sourced: that script solely wraps `cosign` invocations
# by design, not arbitrary fetch-and-verify logic, and the two have
# different default delays (cosign's Rekor uploads vs. GHCR manifest
# reads warrant different tuning).
manifest_backoff_sleep() {
  local attempt="$1" delay half jitter sleep_time
  delay=$(( BASE_DELAY * (1 << (attempt - 1)) ))
  (( delay > MAX_DELAY )) && delay="${MAX_DELAY}"
  half=$(( delay / 2 ))
  jitter=$(( RANDOM % (half + 1) ))
  sleep_time=$(( half + jitter ))
  echo "::notice:: fetch-complete-oci-index: waiting ${sleep_time}s before attempt $((attempt + 1))/${ATTEMPTS}." >&2
  sleep "${sleep_time}"
}

MANIFEST_JSON=""

for attempt in $(seq 1 "${ATTEMPTS}"); do
  CANDIDATE_JSON=$(crane manifest "${IMG}@${DIGEST}")

  complete=true
  for PLATFORM in linux/amd64 linux/arm64; do
    ARCH="${PLATFORM#linux/}"
    IMAGE_DIGEST=$(echo "${CANDIDATE_JSON}" | jq -r --arg arch "${ARCH}" \
      '.manifests[] | select(.platform.architecture == $arch and .platform.os == "linux") | .digest')
    if [[ -z "${IMAGE_DIGEST}" || "${IMAGE_DIGEST}" == "null" ]]; then
      complete=false
      break
    fi
    ATT_DIGEST=$(echo "${CANDIDATE_JSON}" | jq -r --arg ref "${IMAGE_DIGEST}" \
      '.manifests[] | select(.annotations."vnd.docker.reference.type" == "attestation-manifest" and .annotations."vnd.docker.reference.digest" == $ref) | .digest')
    if [[ -z "${ATT_DIGEST}" || "${ATT_DIGEST}" == "null" ]]; then
      complete=false
      break
    fi
  done

  if [[ "${complete}" == "true" ]]; then
    MANIFEST_JSON="${CANDIDATE_JSON}"
    break
  fi

  echo "::warning:: fetch-complete-oci-index: attempt ${attempt}/${ATTEMPTS}: merged index ${IMG}@${DIGEST} is missing an expected image-manifest or attestation-manifest sibling for ${PLATFORM}." >&2
  if [[ "${attempt}" -lt "${ATTEMPTS}" ]]; then
    manifest_backoff_sleep "${attempt}"
  fi
done

if [[ -z "${MANIFEST_JSON}" ]]; then
  echo "::error:: fetch-complete-oci-index: all ${ATTEMPTS} attempts failed to find a complete set of image/attestation manifests in ${IMG}@${DIGEST}." >&2
  echo "::error:: This MAY be a GHCR read-after-write propagation delay under concurrent multi-target publishing, OR a genuine gap in ${HINT} — check both; do not assume either without a second data point." >&2
  exit 1
fi

echo "${MANIFEST_JSON}"