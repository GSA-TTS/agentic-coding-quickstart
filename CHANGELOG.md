# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v3.0.0...v3.1.0) (2026-09-01)


### Features

* **acq:** make --clone a neutral option, emulated on msb via a managed host-side scratch clone ([#423](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/423)) ([7003608](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/70036087afbb00353cd6e2cbc6ee0dea423978db))


### Bug Fixes

* **install:** prefer package managers in auto mode ([#433](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/433)) ([831540d](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/831540d266a7a909d2043571c40b49f824ae22d8))
* **kits:** reject block-scalar environment[] values instead of mangling them ([#420](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/420)) ([02f8531](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/02f8531febeaca4e9d0840b222c5834cc9b63e96))
* **secret:** store macos secrets in keychain via stdin ([#436](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/436)) ([20ab8c7](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/20ab8c79389d5ce11e3894cd9529f30ef3a49dfa))

## [3.0.0](https://github.com/GSA-TTS/agentic-coding-quickstart/compare/v2.0.0...v3.0.0) (2026-08-31)


### ⚠ BREAKING CHANGES

* docs/QUICKSTART.md and docs/QUICKSTART_SBX.md have moved to docs/howto/acq.md and docs/howto/sbx.md. No redirect stubs are kept (this lands ahead of 3.0.0). External links to the old paths break.
* **acq:** on a host with both backends installed and no explicit selection, acq now resolves to msb instead of sbx.
* **acq:** opencode-web.sh is removed. Use the openchamber acq kit to run OpenCode in the browser.

### Features

* **acq:** add a neutral interactive-shell verb — acq shell NAME ([#399](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/399)) ([1862b05](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/1862b05b3b49aff80c76ce6b5595dc61aa98d1e8))
* **acq:** add backend-agnostic --image/ACQ_IMAGE base image override ([#358](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/358)) ([80ae257](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/80ae25722210c5ef85d2ce6edb7c25bb4c938a42))
* **acq:** add per-verb --help for all acq-owned subcommands ([#368](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/368)) ([90f2b4b](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/90f2b4b13f976368d2d437219aca10944a59d545))
* **acq:** default to msb backend and remove qsbx for 3.0.0 ([#266](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/266)) ([21f7901](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/21f7901d751d42777778378afce8cde1ea6678f9))
* **acq:** detect stale sandboxes + acq kit check|update ([#236](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/236)) ([#241](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/241)) ([f1693aa](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/f1693aa6e3c64f640bd84aab2e770c5e58184925))
* **acq:** fix subcommand dispatch hygiene and implement 'secret import' ([#283](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/283)) ([5ae27c6](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/5ae27c682561e35e33d6f1002bcbb9dd79985413))
* **acq:** sand rough edges off first-run onboarding (PATH self-repair + auto host check) ([#281](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/281)) ([71698d7](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/71698d73bc572f67394ffd8a450a2f0651538ebd))
* **acq:** sbx↔msb backend parity, incl. live openchamber-on-msb (omnibus [#234](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/234)) ([#233](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/233)) ([32f9ae0](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/32f9ae0d5a4a70d35381732929766632cab7be35))
* **acq:** scope GitHub token per-sandbox to mounted repos ([#229](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/229)) ([b355706](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/b3557061434607cc0646447444faa0ba956c0f30))
* **install:** add auto-selecting curl|sh installer + streamline README ([#387](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/387)) ([4d67551](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/4d675519e2a0a2638eb84c1302a4ea267f7a2187))
* **install:** enable homebrew tap install ([#424](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/424)) ([5f04294](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/5f042943a55b2be52ddae90e619cbd25f9daf51f))
* **kits:** add neutral volumes vocabulary (sbx v2 5.7 passthrough + msb parity) ([#357](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/357)) ([8029d2a](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/8029d2aec8220b6ed1b89d6be0b8e0d13ea32847))
* **kits:** synthesize chmod from hybrid/v1 mode fields into generated setup.install ([#390](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/390)) ([7a5cb3c](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/7a5cb3ca23bb9891da2686a3da8163e580f3266b))
* **msb:** collapse gateway-DNS grant to allow@dns and re-verify git-HTTPS secret substitution vs msb 0.6.9 ([#318](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/318)) ([491c75c](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/491c75c4a38e3eb7409c075979107802c1953985))
* **msb:** derive default sandbox-template image from agent token ([#409](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/409)) ([cc27fa2](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/cc27fa297daa65ce65fbb6a699eb06f04b4f706b))
* **msb:** diagnose+disambiguate msb egress failures (three signatures) ([#306](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/306)) ([7a6d371](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/7a6d371e20be6e5a58087114e0cd21a2c56af550))
* **msb:** ensure an OCI engine via rootless podman (+ verify-backends fixes, sbx 0.38 floor) ([#302](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/302)) ([8088dcc](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/8088dcca26cd75784769f4f4527393c08ea89851))
* **msb:** forward the host ssh-agent into the guest via --vsock ([#316](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/316)) ([e4e8317](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/e4e831769e872095bdf299084a10242f8a1090cb))
* **msb:** mirror the sbx `balanced` network policy as the msb default egress ([#295](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/295)) ([2c056cb](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/2c056cbed5abdef1f45ecb71ef26151e8bc7ac86))
* **msb:** neutral ACQ_NETWORK_TIER egress selector + deprecate ACQ_MSB_BALANCED_EGRESS ([#310](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/310)) ([2242af4](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/2242af464c91220e423d088a8f8c2ad535c7783d))
* **msb:** re-run kit startup on restart via acq start/restart ([#260](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/260)) ([7bbc999](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/7bbc9993437d0b6a9ae6af7125e2018c9046a40c))
* **msb:** stage kit startup commands as a create-time script ([#259](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/259)) ([3ff736b](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/3ff736bc8f4fce620a1ccdbc2996f50af80e6545))
* **progress:** TTY-aware progress feedback during long acq run phases ([#290](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/290)) ([ab44206](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/ab442060a78b74d122fd7ca9a38d26b1b6d3f9da))
* **sbx:** add actions=read scope to PAT URL ([#262](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/262)) ([fbaa291](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/fbaa29179b0ce70ecfdfcc2b0a9f993e101b5ddc))


### Bug Fixes

* **acq:** accurate git-identity guidance + workspace path pre-flight ([#216](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/216)) ([546cc93](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/546cc9321e9937b96db5b0101a5b647ec80875cf))
* **acq:** carry publishedPorts and quote allow hosts in kit-translate ([#221](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/221)) ([a36d783](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/a36d7835ca0f8fc384486345f2321c809a35fc30))
* **acq:** don't hang key rotation when sbx needs a login ([#211](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/211)) ([#212](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/212)) ([bb0544d](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/bb0544d8c081a4eaba0481a9305a2f4c7a991dff))
* **acq:** enumerate keychain-linux secrets in acq secret ls ([#258](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/258)) ([f4e1bb9](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/f4e1bb9c833f5e3c462c46b9587d8a2abd087c5f))
* **acq:** intercept --kit &lt;ref&gt; on run/create and translate it ([#223](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/223)) ([a86d151](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/a86d1517536307355ae24754b2057a72e2aa9324))
* **acq:** let secret rm remove any stored entry, not just built-ins ([#300](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/300)) ([#301](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/301)) ([ab506ed](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/ab506ed6a4b792dcc04b55588443af37adcd4bbf))
* **acq:** make kit fetch non-interactive; never prompt for git creds ([#207](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/207)) ([#209](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/209)) ([b505336](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/b5053367a1f4996bfe036ec358ab5828bf0feb3f))
* **acq:** make USAi key rotation backend-neutral ([#218](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/218)) ([4a5f8e1](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/4a5f8e1b1a5ee816940178c9d6a85868fb6ae9f3))
* **acq:** persist --kit/extra refs and restore them on start/restart ([#328](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/328)) ([78ec68c](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/78ec68c1e9f2a6b5707c66454290a114123d831e))
* **acq:** propagate host git identity to guest ([#429](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/429)) ([68a6e59](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/68a6e59ed0909ef861c6efea2ad4b7e94f6b6af5))
* **acq:** run fails closed on an unresolvable target instead of silent no-op ([#257](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/257)) ([c0b155c](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/c0b155cb5679fc74b52e5114ada96a8414eed8ef))
* **acq:** run github-scope advisory before provision on fresh create ([#386](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/386)) ([c066206](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/c066206019b5414c2c9ffb090071ebc89e16269d))
* **acq:** store USAi key before sandbox create to end 200-vs-401 split ([#286](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/286)) ([c68ccb6](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/c68ccb6ed0c4af4b735cf7c99be2170023314928))
* Add -f to sbx rm command to cleanup rotation validation sandbox ([#268](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/268)) ([6a21e48](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/6a21e48047e5c0e59a600dbdaf572e2615f8fa1e))
* Avoid literal $MSB_ proxy token ([#324](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/324)) ([548e314](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/548e31483f6d64f07701b03fcc44cf58d76a4f03))
* **http-test:** Ensure the test can install git in alpine ([#325](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/325)) ([a11ece2](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/a11ece2cf67e87bfdebe8755eb5181b500f68420))
* **install:** handle shallow pinned updates ([#428](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/428)) ([2f2eb37](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/2f2eb3704421eada107d0816f81447d21cc04471))
* **kits:** mode validator dropped all kit files on mawk (interval regex) ([#380](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/380)) ([e46f055](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/e46f055438a089b85fe3ec0a1a5ce47e44090b83))
* **kits:** Pull in updated USAi kit with fixed opencode.jsonc config ([#391](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/391)) ([83e0354](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/83e03542e6f6c0488e310260cd5d4f556baacc13))
* **msb:** detect stale ssh-agent --vsock route after a host reboot ([#416](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/416)) ([3568212](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/3568212b7fd99451b47ab24fff0ff683a0ccf271))
* **msb:** install/launch the agent + mount workspaces at their host path ([#230](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/230)) ([0d2bbd0](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/0d2bbd0e830154b412f928f655f20feafb9430ea))
* **msb:** persist kit environment[] and replay it on agent sessions ([#401](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/401)) ([bf89bce](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/bf89bcef55d87a44d97c2e54a7ebbe90f07939f1))
* **msb:** re-drive ssh-agent forward on running reattach ([#392](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/392)) ([ab84c4c](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/ab84c4c8633d79c72e06c4b940d24d52b644a640))
* **opencode-web:** background sbx exec command on host instead of opencode command inside sandbox ([#210](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/210)) ([0a2057e](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/0a2057e3355d4f1bd49703888eee4061ce61cc09))
* **opencode-web:** use serve command and drop per-run port publish ([#204](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/204)) ([5364ffb](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/5364ffba405b2f2574747c9c55bee0c15cb38c93))
* **sbx:** correct lifecycle verbs — sbx has no 'start'/'restart' ([#285](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/285)) ([b69b5d1](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/b69b5d1fae36245789f2cab9b5cd7ee3070d4c49))
* **sbx:** make global secret-set bash-3.2-safe (empty-array under set -u) ([#309](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/309)) ([632a656](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/632a656ede0bddb9d3a4d9a7b3c70ebf2b2e3511))
* **sbx:** stop the every-attach re-attach heal-loop noise on sbx 0.38 ([#327](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/327)) ([24ceb43](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/24ceb436cd457069939549ac814eaaffe3d28c93))
* **secrets:** honor explicit --host for built-in services; unbreak rm -g on bash 3.2 ([#398](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/398)) ([d247a40](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/d247a40525554eb57fb2f240662ec5c9b488ceec)), closes [#384](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/384)
* **tests:** restore real failure detection in the bats suite + repair 56 latent test failures ([#393](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/393)) ([28325bf](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/28325bff98c16b18620a26af6d9df03a324e381a))


### Documentation

* rename QUICKSTART*.md to docs/howto/{acq,sbx}.md ([#361](https://github.com/GSA-TTS/agentic-coding-quickstart/issues/361)) ([0ead93c](https://github.com/GSA-TTS/agentic-coding-quickstart/commit/0ead93ce46e39b61ee1ee3a5f9184d70fec42b89))

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
