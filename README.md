# BAOBAB Development Container

> **Enterprise-grade, reproducible development environment for the BAOBAB Enterprise Platform.**

<!-- Project Badges -->

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-26.04%20LTS-E95420?logo=ubuntu\&logoColor=white)](https://ubuntu.com/)
[![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker\&logoColor=white)](https://www.docker.com/)
[![Dev Containers](https://img.shields.io/badge/Dev%20Containers-Supported-007ACC?logo=visualstudiocode\&logoColor=white)](https://containers.dev/)
[![GitHub Codespaces](https://img.shields.io/badge/GitHub-Codespaces-181717?logo=github\&logoColor=white)](https://github.com/features/codespaces)
[![Build Status](https://github.com/nabhold/baobab-dev/actions/workflows/publish.yml/badge.svg)](https://github.com/nabhold/baobab-dev/actions/workflows/publish.yml)
[![Latest Release](https://img.shields.io/github/v/release/nabhold/baobab-dev?label=Release)](https://github.com/nabhold/baobab-dev/releases)
[![Container Registry](https://img.shields.io/badge/GitHub%20Container%20Registry-GHCR-2ea44f?logo=github)](https://github.com/nabhold/baobab-dev/pkgs/container/baobab-dev)
[![Platform](https://img.shields.io/badge/platform-linux%2Famd64%20%7C%20linux%2Farm64-success)](#supported-platforms)

The **BAOBAB Development Container** provides a deterministic, version-controlled, and enterprise-ready development environment for the **BAOBAB Enterprise Platform**. It enables developers to work from an identical software stack whether using local Docker, Visual Studio Code Dev Containers, GitHub Codespaces, or Continuous Integration (CI) pipelines.

Designed around **Infrastructure as Code (IaC)** principles, the project eliminates configuration drift by defining the complete development environment in source control. Every image is built from a centrally managed version manifest, validated through automated verification, and published as a reproducible OCI-compliant container image.

Unlike traditional development environments that require manual installation and ongoing maintenance, BAOBAB delivers a fully configured workspace that is consistent across machines, operating systems, and team members. This reduces onboarding time, improves collaboration, and ensures that development, testing, and automation all execute against the same trusted foundation.

---

## Why BAOBAB?

Modern software development often suffers from inconsistent tooling, undocumented workstation configuration, and environment-specific issues that are difficult to reproduce.

The BAOBAB Development Container addresses these challenges by providing:

* Deterministic builds through centralized version management.
* Reproducible environments across local development, GitHub Codespaces, Visual Studio Code Dev Containers, and CI.
* Enterprise-grade architecture based on Infrastructure as Code principles.
* Automated verification to ensure every published image is complete and consistent.
* A minimal, maintainable toolchain focused on modern application development.
* Clear separation of concerns between infrastructure, configuration, and version management.

The result is a development platform that is predictable, maintainable, and scalable for both individual developers and engineering teams.

---

## Quick Start

Clone the repository:

```bash
git clone https://github.com/nabhold/baobab-dev.git
cd baobab-dev
```

Open the repository in your preferred development environment:

* **Visual Studio Code** — Reopen in **Dev Container** when prompted.
* **GitHub Codespaces** — Create a new Codespace directly from the repository.
* **Docker** — Build and run the development container locally.

Detailed setup instructions are available in the **Usage** section of this documentation.

---

📖 **Documentation:** https://nabhold.github.io/baobab-dev/

This repository follows a documentation-first approach.

* **README.md** serves as the project's landing page and provides a high-level overview.
* **`docs/`** contains the complete technical documentation covering architecture, usage, reference material, project governance, and operational guidance.

The `docs/` directory is designed to be published through **GitHub Pages**, making the documentation easily accessible online while keeping the repository's landing page concise and approachable.

---

## Table of Contents

### Introduction

* [Overview](docs/introduction/overview.md)
* [Key Features](docs/introduction/key-features.md)
* [Design Principles](docs/architecture/design-principles.md)
* [Supported Platforms](docs/introduction/supported-platforms.md)
* [What's Included](docs/introduction/included.md)
* [What's Not Included](docs/introduction/excluded.md)

### Architecture

* [Repository Structure](docs/architecture/repository-structure.md)
* [Version Management](docs/architecture/version-management.md)
* [Image Architecture](docs/architecture/image-architecture.md)
* [Toolchain](docs/architecture/toolchain.md)
* [Build Process](docs/architecture/build-process.md)

### Usage

* [Running Locally](docs/usage/running-locally.md)
* [GitHub Codespaces](docs/usage/github-codespaces.md)
* [VS Code Dev Containers](docs/usage/vscode-devcontainers.md)

### Reference

* [Build Arguments](docs/reference/build-arguments.md)
* [Environment Variables](docs/reference/environment-variables.md)
* [Helper Commands](docs/reference/helper-commands.md)
* [Build Verification](docs/reference/build-verification.md)
* [Health Checks](docs/reference/health-checks.md)

### Project

* [Security](docs/project/security.md)
* [Contributing](docs/project/contributing.md)
* [Roadmap](docs/project/roadmap.md)
* [License](LICENSE)

### Appendix

* FAQ *(coming soon)*
* Glossary *(coming soon)*
* Common Commands *(coming soon)*
* External References *(coming soon)*
* Support *(coming soon)*
* [Changelog](CHANGELOG.md)
* Acknowledgements *(coming soon)*

## Foundation 4

This repository dogfoods `ghcr.io/nabhold/baobab-dev:1.2.6`. Its SHA-pinned
Foundation gate validates the environment contract and scans both source and
the development-container build. Consumers must pin v1.2.6 profiles explicitly.
