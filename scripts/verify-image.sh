#!/usr/bin/env bash
# =============================================================================
# BAOBAB Enterprise Platform — Container Image Attestation & Verification
# =============================================================================
# File: scripts/verify-image.sh
#
# Purpose:
#   Validates that a target BAOBAB image in GHCR:
#     1. Was signed by GitHub Actions using Cosign keyless OIDC.
#     2. Contains a valid SLSA Provenance attestation predicate.
#     3. Includes a cryptographically bound SPDX SBOM attestation.
#
# Requirements:
#   - cosign (v2.0+)
#
# Usage:
#   ./scripts/verify-image.sh ghcr.io/nabhold/baobab-dev:v1.0.0
#
# CHANGE LOG (this file, most recent first)
# ------------------------------------------------------------------------------
# * [2026-08-18] Step 2's `--type` changed from `slsaprovenance` to
#   `slsaprovenance1`. `cosign attest` in .github/workflows/publish.yml's
#   `publish` job now signs the REAL per-platform SLSA v1 provenance
#   predicates BuildKit computed (extracted via `docker buildx imagetools
#   inspect`), using cosign's `slsaprovenance1` shorthand, which resolves to
#   the `https://slsa.dev/provenance/v1` predicate type. The bare
#   `slsaprovenance` alias this script previously checked resolves to the
#   DIFFERENT `https://slsa.dev/provenance/v0.2` predicate type — attesting
#   under v1 while verifying under v0.2 would never match, regardless of the
#   predicate content being genuine. Both sides must reference the same
#   predicate-type alias; see publish.yml's "Attest container image
#   provenance" step for the attest-side half of this fix.
# =============================================================================

set -Eeuo pipefail

IMAGE="${1:-ghcr.io/nabhold/baobab-dev:v1.0.0}"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
EXPECTED_OWNER_REGEXP="^https://github.com/nabhold"

info() { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
success() { printf "\033[1;32m[SUCCESS]\033[0m %s\n" "$*"; }

info "Starting zero-trust verification for image: ${IMAGE}"
echo "-----------------------------------------------------------------"

# 1. Verify Cosign Keyless OIDC Signature
info "[1/3] Verifying Cosign Keyless OIDC Signature..."
cosign verify \
  --certificate-identity-regexp "${EXPECTED_OWNER_REGEXP}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  "${IMAGE}" > /dev/null

success "Cosign OIDC signature is VALID and belongs to authorized maintainer."
echo ""

# 2. Verify SLSA Provenance Attestation
#
# `--type slsaprovenance1` (not the bare `slsaprovenance` alias — see this
# file's change log above): matches the SLSA v1 predicate type cosign
# actually attests in publish.yml. Two such attestations exist per image
# (one per platform, extracted from BuildKit's own per-platform provenance)
# — this only needs to find one that verifies.
info "[2/3] Verifying SLSA Provenance Attestation..."
cosign verify-attestation \
  --type slsaprovenance1 \
  --certificate-identity-regexp "${EXPECTED_OWNER_REGEXP}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  "${IMAGE}" > /dev/null

success "SLSA Provenance attestation is VALID."
echo ""

# 3. Verify SPDX SBOM Attestation
info "[3/3] Verifying SPDX SBOM Attestation..."
cosign verify-attestation \
  --type spdxjson \
  --certificate-identity-regexp "${EXPECTED_OWNER_REGEXP}" \
  --certificate-oidc-issuer "${OIDC_ISSUER}" \
  "${IMAGE}" > /dev/null

success "SPDX SBOM attestation is VALID."
echo "-----------------------------------------------------------------"
success "🎉 Image ${IMAGE} is authentic, unaltered, and fully attested!"