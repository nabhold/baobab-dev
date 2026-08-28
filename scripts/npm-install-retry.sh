#!/usr/bin/env bash
# =============================================================================
# BAOBAB Enterprise Platform — Bounded Retry Wrapper for `npm install`
# =============================================================================
# File: scripts/npm-install-retry.sh
#
# Defines npm_install_retry(), a drop-in wrapper around `npm install` with
# capped exponential backoff + jitter — the same algorithm
# scripts/cosign-retry.sh already established for Rekor flakiness, applied
# here to a different, npm-specific incident class: a freshly-published
# npm-registry package (npm itself, or any of turbo/tar/playwright/sharp/
# lighthouse) whose own scoped internal dependency hasn't finished
# propagating across the registry's CDN yet, surfacing as a transient
# E404 on an install that will succeed if retried a short while later.
#
# WHY THIS IS A SEPARATE FILE FROM cosign-retry.sh, AND SOURCED RATHER
# THAN EXECUTED AS A SUBPROCESS: cosign-retry.sh is invoked from GitHub
# Actions workflow steps (publish.yml), which run directly on the CI
# runner — a subprocess wrapper works fine there. This one has to run
# INSIDE `docker build`, across more than one Dockerfile stage's RUN
# instruction (with-node, frontend, frontend-e2e) — each RUN is its own
# fresh shell with no memory of functions defined in a previous RUN, and a
# Dockerfile RUN step can't exec a separate script as a subprocess and
# have that subprocess's retry loop affect the CALLING shell's `npm`
# invocation. Sourcing (". .../npm-install-retry.sh") loads the function
# into the current shell instead, so each call site can wrap its own
# "npm install -g ..." or "npm install <pkg> --no-save" invocation with
# whatever exact arguments it already uses, unchanged.
#
# INCIDENT HISTORY:
#   2026-08-28 (1st) — `npm install -g npm@latest` failed on every build
#     matrix leg simultaneously (E404 on an internal @npmcli/* dependency
#     of whatever npm had just published as `latest`). Root-caused to
#     `npm@latest`/`tar@latest` floating at DOCKER BUILD time instead of
#     resolving once in resolve.sh like every other tool in this file;
#     fixed by adding NPM_VERSION/NPM_BUNDLED_TAR_VERSION to
#     versions.yaml so both freeze into versions.lock.
#   2026-08-28 (2nd, same day) — recurred against the CORRECTLY resolved
#     NPM_VERSION itself: the version number resolved fine (a real,
#     existing semver), but that exact version's own `@npmcli/docs`
#     dependency 404'd. Proved that resolving "latest" once in resolve.sh
#     does not, by itself, protect against this incident class — the
#     lookup succeeding is not the same as the resolved version being
#     fully installable yet. The fix has to retry the INSTALL itself,
#     with backoff, not the version lookup.
#
# This file exists so that fix is applied at every npm-registry-package
# install site in the Dockerfile (with-node's npm/tar, frontend's turbo,
# frontend-e2e's playwright/sharp/lighthouse) instead of only the one
# call site that had already failed twice by the time this was written.
#
# Usage (from inside a Dockerfile RUN instruction, after sourcing this
# file):
#   . "${BAOBAB_CONFIG_DIR}/npm-install-retry.sh"
#   npm_install_retry -g "npm@${NPM_VERSION}"
#   npm_install_retry "tar@${NPM_BUNDLED_TAR_VERSION}" --no-save
#   npm_install_retry -g "turbo@${TURBO_VERSION}"
#   npm_install_retry -g "playwright@${PLAYWRIGHT_VERSION}" "sharp@${SHARP_VERSION}" "lighthouse@${LIGHTHOUSE_VERSION}"
#
# All arguments after the function name are passed through to
# `npm install` verbatim, unchanged, on every attempt.
#
# Configuration (optional, via environment — same shape as
# cosign-retry.sh's COSIGN_RETRY_*, distinct names so the two never
# collide if a future step ever needed both sourced in the same shell):
#   NPM_INSTALL_RETRY_ATTEMPTS    Attempts before giving up. Default: 5.
#   NPM_INSTALL_RETRY_BASE_DELAY  Seconds, backoff base (doubles each
#                                 attempt). Default: 15.
#   NPM_INSTALL_RETRY_MAX_DELAY   Seconds, cap on any single delay.
#                                 Default: 120.
#
# Return value: 0 if `npm install` eventually succeeded, 1 if every
# attempt failed.
# =============================================================================

npm_install_retry() {

    local attempts="${NPM_INSTALL_RETRY_ATTEMPTS:-5}"
    local base_delay="${NPM_INSTALL_RETRY_BASE_DELAY:-15}"
    local max_delay="${NPM_INSTALL_RETRY_MAX_DELAY:-120}"
    local attempt=1 delay half jitter
    local label="npm install $*"

    # Capped exponential backoff with "equal jitter" (half fixed, half
    # random): guarantees a real minimum wait every attempt while still
    # avoiding synchronized retries. delay = min(base * 2^(n-1), max) —
    # identical algorithm to cosign-retry.sh's backoff_sleep().
    until npm install "$@"; do
        if (( attempt >= attempts )); then
            echo "npm_install_retry: all ${attempts} attempts failed for: ${label}" >&2
            return 1
        fi

        delay=$(( base_delay * (1 << (attempt - 1)) ))
        (( delay > max_delay )) && delay="${max_delay}"
        half=$(( delay / 2 ))
        jitter=$(( RANDOM % (half + 1) ))
        delay=$(( half + jitter ))

        echo "npm_install_retry: attempt ${attempt}/${attempts} failed for: ${label} -- retrying in ${delay}s (likely npm-registry CDN propagation lag on a freshly-published version)." >&2
        sleep "${delay}"
        attempt=$(( attempt + 1 ))
    done
}