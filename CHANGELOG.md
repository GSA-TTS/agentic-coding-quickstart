# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.10.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.9.0...v0.10.0) (2026-06-12)


### Features

* add key rotation script ([6503fc8](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/6503fc80848d9dfe3d5f48eca5bf3b9a473bf638))
* Better rotation script. ([33c22a1](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/33c22a135258c17f2433c7d833bb5b3a5b13a222))
* **qsbx:** validate USAi key and offer rotation before attach ([#143](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/143)) ([14c4cc5](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/14c4cc583d86811410b5f6af7dca1b7debe38a90)), closes [#140](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/140)
* **sync:** automate USAI model sync for opencode templates ([26e777b](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/26e777bebac5e658226841448fc48e54cb14d47c)), closes [#117](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/117) [#118](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/118) [#119](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/119)
* **template:** add comprehensive commented examples for OpenCode config ([#123](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/123)) ([0ed5771](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/0ed5771b9d33498a8c30580b5cadec11e3890e96))
* **template:** add headers for agentic traffic identification ([#125](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/125)) ([a54f7e6](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/a54f7e635bac90e0d55c40ac707d48f2fe7b15ee))


### Bug Fixes

* Apply suggestion from [@mogul](https://github.com/mogul) ([edeba92](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/edeba922b22309946aae81979aea4e9eec0bfdc6))
* **ci:** add permissions block to release workflow ([#129](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/129)) ([27b019e](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/27b019ede8822074705b20fe0b15fe3cbfc64626))
* **ci:** correct action SHA pins for usai-model-sync workflow ([1579774](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/15797744c9e7b613282edcecf34a19f29800acd5))
* **ci:** track package-lock.json for reproducible CI builds ([59762bd](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/59762bd86a2a5a3d6b084c17071c1080c2adce49))
* **ci:** update markdownlint-cli2-action SHA to v23.2.0 ([#135](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/135)) ([3b38acb](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/3b38acb67d12f6beb405f9fb8c88b5e01e460c84))
* clarify rotation steps ([4e6255f](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/4e6255fd5102d1986e650d551deafc22bda20d77))
* clarify rotation steps ([934497d](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/934497db283bc0a417249b1e02f6e4670bbc9914))
* Formatting, typos ([ef65361](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/ef65361ccdc0ccc44f4f2c4185a3b1d55d0907fb))
* opencode PR suggestion bugs ([9ce4664](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/9ce46642435a9464147c87ed2b18089c564a3cf0))
* prettier, formatting, and fix link to guidance ([dec8d11](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/dec8d11667c70a79fed2328bdb3ff3e35aa5b70f))
* **sync:** improve API error messages for debugging ([2bcf082](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/2bcf0821b14960ef3e18a78a9fe688fe28a4d694))
* Use QS_SBX var ([ad17ad7](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/ad17ad7a4a18616dfe58b0c51f2a8e724946e1a3))
* **web:** run opencode web detached via sbx exec ([#147](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/147)) ([70cf626](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/70cf62699f2ac6e6d1b5711768f069326bcff127))

## [0.9.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.8.1...v0.9.0) (2026-05-29)

### Features

* add opencode web ([b462efc](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/b462efc34a71c2264e8f56f40832d57665d07178))
* add opencode web ([#86](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/86)) ([b462efc](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/b462efc34a71c2264e8f56f40832d57665d07178))

### Bug Fixes

* reconcile files used in init-project and update makefile to current standards ([#82](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/82)) ([5e2f529](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/5e2f529d13f3b660a95ae60a2d4f4a761ca3d8b5))

## [0.8.1](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.8.0...v0.8.1) (2026-05-28)

### Bug Fixes

* **docs:** correct broken related_files links in frontmatter ([#74](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/74)) ([2af5b26](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/2af5b26272bfafd46568b20620e8a1bdca18e0be))

## [0.8.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.7.0...v0.8.0) (2026-05-28)

### Features

* **bootstrap:** add init-project script for project bootstrapping ([#70](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/70)) ([0715e19](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/0715e1958535d8435a1087fb5dcdc4a5ddc3faf5))

### Bug Fixes

* use `sbx secret set-custom` for USAI_API_KEY ([#57](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/57)) ([56da7c5](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/56da7c523b88e6a7093091bc86f3a31bf846c9b3))

## [0.7.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.6.1...v0.7.0) (2026-05-27)

### Features

* **zed:** add zed editor integration and task runner setup ([#45](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/45)) ([0aff745](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/0aff745145dd4a51a49f90454abfe01d531127dd))

## [0.6.1](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.6.0...v0.6.1) (2026-05-27)

### Bug Fixes

* correct invocations of sbx version and policy ([#36](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/36)) ([d2ff60e](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/d2ff60eb3d41fbe17bc14e7220c63f67e6a37a36))

## [0.6.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.5.0...v0.6.0) (2026-05-26)

### Features

* **ci:** add minimal pre-commit config (opt-in) for secret detection ([#35](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/35)) ([b40149a](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/b40149af97edfe6e9007d2defe18815ea74f33e5)), closes [#34](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/34)
* **config:** expand opencode.jsonc with models, permissions, and compaction ([#29](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/29)) ([b6270ca](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/b6270ca1ef2eb905f54cf5b3873c0723d5392af5))

## [0.5.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.4.0...v0.5.0) (2026-04-22)

### Features

* add workspace structure and makefile for simplified setup ([#20](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/20)) ([abd22e8](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/abd22e8629b7912b5cc34835b37c4457fe7f7cee))

## [0.4.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.3.0...v0.4.0) (2026-04-14)

### Features

* **templates:** add bootstrap files for copying quickstart to other repos ([7ea07e7](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/7ea07e782a7623588415a97cef8884a667299b64))

## [0.3.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.2.0...v0.3.0) (2026-04-14)

### Features

* add semver, conventional commits, and automated releases ([#12](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/12)) ([5c3cdfb](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/5c3cdfb0c11f16d8253500bfcadf299abedd07c1))

### Bug Fixes

* **ci:** migrate from hello-please to release-please ([583dca5](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/583dca5c3390268536aad47ff8323726855660d2))
