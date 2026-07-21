# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v1.0.1...v2.0.0) (2026-07-21)


### ⚠ BREAKING CHANGES

* **acq:** qsbx now requires sbx >= 0.35.0. sbx 0.35.x has no Linux/ARM64 build (deferred to 0.36.x), so Linux/ARM64 hosts cannot meet the floor until 0.36.x.

### Features

* **acq:** add msb backend and neutral hybrid/v1 kit translation ([#202](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/202)) ([f993250](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/f99325034ab803c2b5609c100ebc8bcc896c524f))
* **acq:** add pluggable-backend acq wrapper (sbx driver) and deprecate qsbx ([#201](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/201)) ([fbd57be](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/fbd57be188974510ebf30d856aa86f1e55d24218))


### Bug Fixes

* **sbx:** recover sandboxes with orphaned USAi placeholders ([#196](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/196)) ([58f58f9](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/58f58f9e64de63c70aa08565763312c7ef64af1a))

## [1.0.1](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v1.0.0...v1.0.1) (2026-07-08)


### Bug Fixes

* **sbx:** align qsbx docs/verify with v1.5.0 usai-provider global-config merge ([#194](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/194)) ([e1622f6](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/e1622f602d8d52279df57adf9c9c9cd7e6e1ee37))

## [1.0.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.11.0...v1.0.0) (2026-07-07)


### ⚠ BREAKING CHANGES

* **sbx:** the agentic-coding-playbook git submodule is removed. Existing clones should run `git submodule deinit -f agentic-coding-playbook` after pulling. The playbook is now delivered into sandboxes by the playbook kit, not the submodule.

### Features

* **sbx:** bump patterns kit ref to v1.5.0 release ([#193](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/193)) ([f6f57d5](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/f6f57d58c22e52343994139d32bcc3e838d26910))
* **sbx:** deliver USAi config and the playbook as sbx mixin kits ([#184](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/184)) ([88f121a](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/88f121acfacb67a53bc0baff5e0783d459da92ed))


### Bug Fixes

* **docs:** Remove duplicate &lt;details&gt; tag that breaks rendering of README ([#192](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/192)) ([809154b](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/809154bc236060ad2aed53beb4ac85c7d8a220ff))

## [0.11.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.10.1...v0.11.0) (2026-07-01)


### Features

* **opencode:** reduce read/inspection approval fatigue in permissions ([#179](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/179)) ([e840ae4](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/e840ae4f5fbcfa0e412b1bfdbc3f26f45cb22525))


### Bug Fixes

* **docs:** harden Docker install (no curl|sudo sh) ([#187](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/187)) ([1706af3](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/1706af37caf5028ab6249465cf3d7133409e0541))
* **qsbx:** repair stale usai placeholders ([#182](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/182)) ([4b3c7e0](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/4b3c7e00ebe6c11ff46dc021655bf97aaf628c45))

## [0.10.1](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v0.10.0...v0.10.1) (2026-06-26)


### Bug Fixes

* correct CODING_PRACTICES.md link ([#176](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/176)) ([3beba66](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/3beba66507a965f5e775562467740ce77f31ec43))
* **qsbx:** consolidate duplicate USAi secrets and attach by --name ([#159](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/159)) ([039013f](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/039013f792d2b8d490a45b0d13c8845883aab4d0))

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
