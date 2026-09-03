# Changelog

All notable changes to the BAOBAB devcontainer image are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
versioning follows [Semantic Versioning](https://semver.org/) as described
in `README.md § Versioning strategy`.

## [1.3.0-rc.0] — Java + Maven for iDempiere

### Added
- Eclipse Temurin OpenJDK 17 (JDK, not JRE) in the `full` profile, installed
  from Adoptium's own apt repository (multi-arch: `linux/amd64` and
  `linux/arm64`). Required by `baobab-erp`'s iDempiere ERP engine migration
  (github.com/nabhold/baobab-erp) — not used by any other BAOBAB engine.
- Apache Maven 3.9.16 in the `full` profile, installed from
  `archive.apache.org` and verified against its published SHA-512 checksum.
  Pinned explicitly rather than tracked at "latest": Maven Central's release
  metadata currently resolves `latest`/`release` to a `4.0.0` pre-release,
  which would be incompatible with iDempiere's documented Maven 3.9.x
  requirement.
- `config/capabilities.yaml`: `languages.java` and `development.maven`
  declared under the `full` profile.
- `scripts/verify.sh`: new "Java" section checking `java`, `javac`, and
  `mvn`, gated on `BAOBAB_BUILD_PROFILE=full` like the other full-profile-only
  checks.

### Fixed
- The `base` stage's OCI `image.source` and `image.documentation` labels
  pointed at `github.com/nabhold/baobab-devcontainer`, a repository name this
  project has never used. Both now correctly point at
  `github.com/nabhold/baobab-dev`.
- CI's "scan built container with Trivy" step failed on both `linux/amd64`
  and `linux/arm64` `final` builds: Trivy's secret scanner flagged three
  placeholder credential-shaped values inside Maven's own stock
  `conf/settings.xml` documentation comments as HIGH-severity secrets (raw
  byte pattern matching, not XML-comment-aware — not a real secret). Fixed
  by stripping all XML comments from the installed `settings.xml` at build
  time; Maven's actual behavior (`mvn --version` and every other invocation)
  is unaffected.
- That fix initially shipped as its own trailing `RUN` layer, and CI kept
  failing with the identical pre-fix findings even once confirmed running
  against the commit containing it — a stale BuildKit cache hit on that
  layer, since the extraction instruction immediately before it was
  legitimately unchanged from the prior commit and stayed cacheable. Merged
  the extraction and the comment-stripping into a single `RUN` instruction
  so the combined instruction text is itself new, guaranteeing a fresh
  cache key independent of any neighboring layer.

## [1.0.0] — Baseline release

### Added
- Ubuntu 26.04 LTS base with multi-stage build (Flutter SDK stage, pinned
  CLI-tools stage, final runtime stage).
- Python 3.14 via deadsnakes, with pipx, uv, and Poetry (in-project venvs).
- Node.js 24.x LTS with npm, pnpm, and yarn via Corepack.
- Flutter (stable) + bundled Dart SDK, precached for non-mobile targets.
- PostgreSQL 17 client and Redis CLI (client tools only).
- Docker CLI, Compose plugin, Buildx plugin (no daemon).
- GitHub CLI.
- ripgrep, fd, bat, eza, fzf, tmux, bash-completion, colored prompt,
  curated aliases, and improved history configuration.
- Non-root `vscode` user (UID/GID 1000) with passwordless sudo.
- `baobab-verify` and `baobab-summary` operational scripts.
- `devcontainer.json` with VS Code extensions/settings for Python, Ruff,
  Black, isort, mypy, Docker, Flutter/Dart, GitHub Actions, Markdown, YAML.
- `post-create.sh` (project dependency install) and `bootstrap.sh`
  (standalone onboarding) lifecycle scripts.
- Multi-arch (`linux/amd64`, `linux/arm64`) GitHub Actions build/publish
  workflow with GHCR publishing and cosign keyless signing.
