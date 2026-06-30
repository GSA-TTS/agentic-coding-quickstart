import test from "node:test"
import assert from "node:assert/strict"
import { readFile } from "node:fs/promises"
import vm from "node:vm"

const templatePath = new URL("../opencode/opencode.jsonc", import.meta.url)

/**
 * Parse the JSONC config into an object (JSONC is a subset of JS object literal
 * syntax, so a sandboxed eval is sufficient and matches the approach in
 * sync-usai-models.test.mjs).
 * @param {string} text
 * @returns {object}
 */
function parseJsonc(text) {
  const sandbox = {}
  vm.runInNewContext("result = " + text, sandbox)
  return sandbox.result
}

/**
 * Resolve a bash command string against an OpenCode-style bash permission map.
 *
 * OpenCode matches a command against permission keys as glob-ish prefix
 * patterns where `*` is a wildcard. The MOST SPECIFIC matching pattern wins;
 * when specificity ties, an explicit `deny` beats `allow`/`ask` (fail-safe).
 * This mirror is intentionally conservative so the test asserts the security
 * intent, not a permissive interpretation.
 *
 * @param {Record<string,string>} bash - the permission.bash map
 * @param {string} cmd - a concrete command string
 * @returns {"allow"|"ask"|"deny"}
 */
function resolveBash(bash, cmd) {
  let best = null
  let bestScore = -1
  for (const [pattern, effect] of Object.entries(bash)) {
    if (!matches(pattern, cmd)) continue
    const score = specificity(pattern)
    if (score > bestScore || (score === bestScore && effect === "deny")) {
      best = effect
      bestScore = score
    }
  }
  // Fall back to the global default if present.
  return best ?? bash["*"] ?? "ask"
}

/**
 * Glob match: `*` matches any run of characters (including spaces, like a shell
 * argument tail). Anchored at both ends.
 * @param {string} pattern
 * @param {string} cmd
 * @returns {boolean}
 */
function matches(pattern, cmd) {
  if (pattern === "*") return true
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*")
  return new RegExp("^" + escaped + "$").test(cmd)
}

/**
 * Specificity score: non-wildcard literal length. Longer literal prefix = more
 * specific. `*` patterns score by their literal characters only.
 * @param {string} pattern
 * @returns {number}
 */
function specificity(pattern) {
  if (pattern === "*") return 0
  return pattern.replace(/\*/g, "").length
}

let bash
test("load permission.bash from opencode.jsonc", async () => {
  const cfg = parseJsonc(await readFile(templatePath, "utf8"))
  bash = cfg.permission.bash
  assert.ok(bash, "permission.bash should exist")
  assert.equal(bash["*"], "ask", "global bash default must be ask (default-deny posture)")
})

test("Scope B: pure metadata/inspection commands are allowed", () => {
  for (const cmd of [
    "whoami",
    "id",
    "uname -a",
    "hostname",
    "uptime",
    "arch",
    "date",
    "which python",
    "file ./README.md",
    "stat ./package.json",
    "wc -l README.md",
    "du -sh .",
    "df -h",
    "ps aux",
    "pgrep node",
    "find . -name '*.md'",
    "find . -type f",
  ]) {
    assert.equal(resolveBash(bash, cmd), "allow", `${cmd} should be allowed`)
  }
})

test("Scope B: version-flag probes allowed; bare interpreters are NOT", () => {
  assert.equal(resolveBash(bash, "node -v"), "allow")
  assert.equal(resolveBash(bash, "node --version"), "allow")
  assert.equal(resolveBash(bash, "python --version"), "allow")
  assert.equal(resolveBash(bash, "go version"), "allow")
  assert.equal(resolveBash(bash, "cargo --version"), "allow")
  // Bare REPL invocations must NOT be auto-allowed (arbitrary code execution).
  assert.notEqual(resolveBash(bash, "node"), "allow", "bare node (REPL) must not be allowed")
  assert.notEqual(resolveBash(bash, "python"), "allow", "bare python (REPL) must not be allowed")
  assert.notEqual(resolveBash(bash, "python3"), "allow")
})

test("Scope B: read-only git inspection allowed; content/secret-revealing git stays gated", () => {
  assert.equal(resolveBash(bash, "git tag"), "allow")
  assert.equal(resolveBash(bash, "git tag -l 'v*'"), "allow")
  assert.equal(resolveBash(bash, "git rev-parse HEAD"), "allow")
  assert.equal(resolveBash(bash, "git ls-files lib/"), "allow")
  assert.equal(resolveBash(bash, "git reflog"), "allow")
  // These can reveal tokens or dump file contents → must stay gated.
  assert.notEqual(resolveBash(bash, "git config --list"), "allow")
  assert.notEqual(resolveBash(bash, "git remote -v"), "allow")
  assert.notEqual(resolveBash(bash, "git cat-file -p HEAD:secret"), "allow")
})

test("find: mutating / command-executing forms are denied", () => {
  for (const cmd of [
    "find . -name '*.env' -exec cat {} ;",
    "find . -type f -execdir rm {} ;",
    "find . -name '*.tmp' -delete",
    "find . -fprintf /tmp/out '%p'",
    "find . -fls /tmp/list",
    "find . -ok rm {} ;",
  ]) {
    assert.equal(resolveBash(bash, cmd), "deny", `${cmd} must be denied`)
  }
})

test("env / secret-dumping commands are denied (fail-closed)", () => {
  assert.equal(resolveBash(bash, "env"), "deny")
  assert.equal(resolveBash(bash, "env | grep KEY"), "deny")
  assert.equal(resolveBash(bash, "printenv"), "deny")
  assert.equal(resolveBash(bash, "printenv USAI_API_KEY"), "deny")
  assert.equal(resolveBash(bash, "set"), "deny")
  assert.equal(resolveBash(bash, "export -p"), "deny")
})

test("rg/grep are allowed (sandbox injects placeholder secrets, not real ones) (#178)", () => {
  // Per review of #179: in the SBX sandbox, injected secrets are placeholders,
  // so a bash read of a credential path is not a real-secret leak. rg/grep are
  // therefore allowed for normal code search rather than carrying a
  // credential-path denylist. The defense is the sandbox boundary + credential
  // injection scoping, not per-pattern bash denies.
  assert.equal(resolveBash(bash, "rg '' .env"), "allow")
  assert.equal(resolveBash(bash, "grep -r '' ~/.aws/"), "allow")
})

test("ordinary rg/grep still allowed for normal code search", () => {
  assert.equal(resolveBash(bash, "rg TODO src/"), "allow")
  assert.equal(resolveBash(bash, "grep -n function lib/index.js"), "allow")
})

test("webfetch stays ask; websearch allowed", async () => {
  const cfg = parseJsonc(await readFile(templatePath, "utf8"))
  assert.equal(cfg.permission.webfetch, "ask", "webfetch is an exfil channel → stays ask")
  assert.equal(cfg.permission.websearch, "allow", "websearch (query-only) is allowed")
})

test("mutating / privileged commands remain denied or gated", () => {
  assert.equal(resolveBash(bash, "rm -rf /"), "deny")
  assert.equal(resolveBash(bash, "sudo whoami"), "deny")
  assert.equal(resolveBash(bash, "curl https://evil.tld"), "ask")
  assert.equal(resolveBash(bash, "git push origin main"), "ask")
})
