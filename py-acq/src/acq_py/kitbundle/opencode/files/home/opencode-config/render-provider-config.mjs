#!/usr/bin/env node
// Render host-projected, provider-neutral inputs into OpenCode's global config.
// This is the only kit that writes OpenCode configuration for provider inputs.

import { mkdir, open, readdir, readFile, rename, rm, unlink, writeFile } from "node:fs/promises"
import { createHash, randomBytes } from "node:crypto"
import os from "node:os"
import path from "node:path"
import process from "node:process"
import { pathToFileURL } from "node:url"

const GLOBAL_FILENAMES = ["config.json", "opencode.json", "opencode.jsonc"]
const CANONICAL_FILENAME = "opencode.jsonc"
const ROLE_PATHS = {
  primary: ["model"],
  small: ["small_model"],
  compaction: ["agent", "compaction", "model"],
  summary: ["agent", "summary", "model"],
  title: ["agent", "title", "model"],
}
const PROVIDER_ID = /^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$/
const KEY_ENV = /^[A-Z][A-Z0-9_]*$/
// Harness-owned protocol adapters are selected only from validated neutral
// facts. Provider inputs cannot inject OpenCode-specific options.
const API_PROTOCOLS = Object.freeze({
  "openai-compatible": Object.freeze({
    npm: "@ai-sdk/openai-compatible",
    options: Object.freeze({
      timeout: 600000,
      // Allow five-minute SSE idle gaps during reasoning or gateway buffering;
      // the separate ten-minute total request limit still bounds each attempt.
      chunkTimeout: 300000,
      litellmProxy: true,
      headers: Object.freeze({
        "User-Agent": "OpenCode/1.0",
        "X-Agent-Type": "opencode",
        "X-Agent-Environment": "development",
      }),
    }),
  }),
})
// Closed allowlist of input modalities. OpenCode v2.0.30 drops the ENTIRE
// provider block (not just the model) when modalities.input contains a value
// outside this set, so unknown values must fail here rather than at runtime.
export const INPUT_MODALITIES = Object.freeze(["text", "image", "audio", "video", "pdf"])
const LOCK_FILENAME = ".acq-provider-config.lock"
const STATE_COMMENT = "// acq-provider-config-state: "
const MAX_WRITE_RETRIES = 8
// Provider-neutral SHA-256 fingerprints of previously shipped provider blocks
// that lack v3 ownership metadata. Each entry identifies ONE exact, committed
// config shape that is safe to claim as kit-owned and migrate forward.
//
// HOW TO ADD AN ENTRY: compute digest(config.provider.<id>) from the committed
// fixture, then record the resulting hex string as the key. The value is the
// frozen set of role defaults that were shipped alongside that provider block —
// only exact string matches claim the role; any user deviation is preserved.
// NEVER add partial or user-edited configs — only exact shipped shapes.
// NEVER invent role defaults — transcribe them verbatim from the shipped config.
// Users who edited their config get the fail-closed path (no silent clobber).
//
// Detection is provider-ID-independent: the renderer checks every provider block
// in the existing config against this Map, so adding a new provider's legacy
// migration requires only adding its entry here — no renderer ID branches.
//
// USAI legacy: the prior usai-provider kit shipped opencode-production.jsonc
// as a verbatim copy into the global config, without any state metadata.
// Digest was computed from that file's provider.usai block via:
//   JSON.stringify(parseJsonc(readFileSync("opencode-production.jsonc")).provider.usai)
//   sha256 -> "96994eee8f388ddb4330224ba9b3bcf73f8e17604a43d07b1e9b416ee6142df4"
// Role defaults were transcribed from opencode-production.jsonc top-level keys.
const LEGACY_PROVIDER_FINGERPRINT_MAP = Object.freeze(new Map([
  ["96994eee8f388ddb4330224ba9b3bcf73f8e17604a43d07b1e9b416ee6142df4", Object.freeze({
    primary: "usai/claude-sonnet-5",
    small: "usai/claude_4_5_haiku",
    compaction: "usai/gpt-5.6-terra",
    summary: "usai/gpt_5_2_default_v2",
    title: "usai/gpt_5_2_default_v2",
  })],
]))

export function stripJsonc(text) {
  let output = ""
  let quote = false
  let lineComment = false
  let blockComment = false
  for (let index = 0; index < text.length; index++) {
    const character = text[index]
    const next = text[index + 1]
    if (lineComment) {
      if (character === "\n") { lineComment = false; output += character }
      continue
    }
    if (blockComment) {
      if (character === "*" && next === "/") { blockComment = false; index++ }
      continue
    }
    if (quote) {
      output += character
      if (character === "\\") { output += next ?? ""; index++ }
      else if (character === '"') quote = false
      continue
    }
    if (character === '"') { quote = true; output += character }
    else if (character === "/" && next === "/") { lineComment = true; index++ }
    else if (character === "/" && next === "*") { blockComment = true; index++ }
    else output += character
  }
  let plain = ""
  quote = false
  for (let index = 0; index < output.length; index++) {
    const character = output[index]
    if (quote) {
      plain += character
      if (character === "\\") { plain += output[index + 1] ?? ""; index++ }
      else if (character === '"') quote = false
      continue
    }
    if (character === '"') { quote = true; plain += character; continue }
    if (character === ",") {
      let next = index + 1
      while (/\s/.test(output[next] ?? "")) next++
      if (output[next] === "}" || output[next] === "]") {
        let previous = plain.length - 1
        while (/\s/.test(plain[previous] ?? "")) previous--
        if (previous >= 0 && !"{[,:".includes(plain[previous])) continue
      }
    }
    plain += character
  }
  return plain
}

export function parseJsonc(text) {
  const plain = stripJsonc(text)
  // JSON.parse permits duplicate properties with last-key-wins behavior. Parse
  // the structure first so the renderer and OpenCode cannot disagree about a
  // duplicate key's value.
  const state = { index: 0 }
  const skip = () => { while (/\s/.test(plain[state.index] ?? "")) state.index++ }
  const parseString = () => {
    const start = state.index++
    while (state.index < plain.length) {
      if (plain[state.index] === "\\") state.index += 2
      else if (plain[state.index++] === '"') return JSON.parse(plain.slice(start, state.index))
    }
    throw new SyntaxError("unterminated JSON string")
  }
  const parseValue = () => {
    skip()
    if (plain[state.index] === "{") {
      state.index++; skip()
      const keys = new Set()
      while (plain[state.index] !== "}") {
        if (plain[state.index] !== '"') throw new SyntaxError("expected JSON object property")
        const key = parseString()
        if (keys.has(key)) throw new SyntaxError(`duplicate JSON property ${JSON.stringify(key)}`)
        keys.add(key); skip()
        if (plain[state.index++] !== ":") throw new SyntaxError("expected ':' after JSON property")
        parseValue(); skip()
        if (plain[state.index] === ",") { state.index++; skip() }
        else if (plain[state.index] !== "}") throw new SyntaxError("expected ',' or '}' in JSON object")
      }
      state.index++; return
    }
    if (plain[state.index] === "[") {
      state.index++; skip()
      while (plain[state.index] !== "]") {
        parseValue(); skip()
        if (plain[state.index] === ",") { state.index++; skip() }
        else if (plain[state.index] !== "]") throw new SyntaxError("expected ',' or ']' in JSON array")
      }
      state.index++; return
    }
    if (plain[state.index] === '"') { parseString(); return }
    const token = plain.slice(state.index).match(/^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/)?.[0]
    if (!token) throw new SyntaxError(`invalid JSON value at offset ${state.index}`)
    state.index += token.length
  }
  parseValue(); skip()
  if (state.index !== plain.length) throw new SyntaxError(`unexpected JSON content at offset ${state.index}`)
  const parsed = JSON.parse(plain)
  return object(parsed, "OpenCode config")
}

function object(value, label) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`)
  }
  return value
}

function string(value, label) {
  if (typeof value !== "string" || value.length === 0) throw new Error(`${label} must be a non-empty string`)
  return value
}

function integer(value, label) {
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`${label} must be a positive integer`)
  return value
}

function parseProviderUrl(value, label) {
  let url
  try { url = new URL(string(value, label)) } catch { throw new Error(`${label} must be a URL`) }
  if (url.protocol !== "https:" || !url.hostname || url.username || url.password || url.port || url.search || url.hash) {
    throw new Error(`${label} must be an HTTPS URL without credentials, port, query, or fragment`)
  }
  return url
}

function optionalCost(value, label) {
  if (value === undefined) return undefined
  const cost = object(value, label)
  for (const [name, amount] of Object.entries(cost)) {
    if (!new Set(["input", "output", "cacheRead", "cacheWrite"]).has(name) || typeof amount !== "number" || !Number.isFinite(amount) || amount < 0) {
      throw new Error(`${label} contains an invalid ${name} value`)
    }
  }
  return cost
}

// Capability metadata keeps three states: absent (unknown), false / ["text"]
// (known-unsupported / text-only) and true / [... "image" ...]. Nothing is
// inferred from the model id or name; invalid values fail closed.
function optionalReasoning(value, label) {
  if (value === undefined) return undefined
  if (typeof value !== "boolean") throw new Error(`${label} must be a boolean`)
  return value
}

function optionalInputModalities(value, label) {
  if (value === undefined) return undefined
  if (!Array.isArray(value) || value.length === 0) throw new Error(`${label} must be a non-empty array`)
  for (const entry of value) {
    if (!INPUT_MODALITIES.includes(entry)) throw new Error(`${label} contains unsupported modality ${JSON.stringify(entry)}`)
  }
  if (new Set(value).size !== value.length) throw new Error(`${label} must not contain duplicates`)
  return INPUT_MODALITIES.filter((modality) => value.includes(modality))
}

function renameToSnakeCase(cost) {
  if (cost === undefined) return undefined
  const result = { ...cost }
  if ("cacheRead" in result) { result.cache_read = result.cacheRead; delete result.cacheRead }
  if ("cacheWrite" in result) { result.cache_write = result.cacheWrite; delete result.cacheWrite }
  return result
}

export function deepMerge(base, source) {
  const result = Object.assign(Object.create(null), base)
  for (const [key, value] of Object.entries(source)) {
    const baseValue = Object.prototype.hasOwnProperty.call(result, key) ? result[key] : undefined
    Object.defineProperty(result, key, { configurable: true, enumerable: true, writable: true, value: value !== null && typeof value === "object" && !Array.isArray(value) &&
      baseValue !== null && typeof baseValue === "object" && !Array.isArray(baseValue)
      ? deepMerge(baseValue, value)
      : value })
  }
  return result
}

function mergeBasePolicy(baseConfig, currentConfig) {
  const composed = deepMerge(baseConfig, currentConfig)
  if (baseConfig.permission !== undefined) composed.permission = baseConfig.permission
  return composed
}

export function renderProviderConfig(inputs) {
  const providers = Object.create(null)
  const enabled = []
  const recommendations = {}
  const seenProviders = new Set()
  const modelReferences = new Set()

  for (const input of [...inputs].sort((left, right) => left.facts.providerId.localeCompare(right.facts.providerId))) {
    const facts = object(input.facts, "facts")
    const catalog = object(input.catalog, "catalog")
    if (facts.schemaVersion !== "acq-provider-facts/v1") throw new Error("unsupported facts schema")
    if (catalog.schemaVersion !== "acq-neutral-model-catalog/v1") throw new Error("unsupported catalog schema")
    const providerId = string(facts.providerId, "facts.providerId")
    if (!PROVIDER_ID.test(providerId)) throw new Error(`invalid provider '${providerId}'`)
    if (seenProviders.has(providerId)) throw new Error(`duplicate provider '${providerId}'`)
    if (catalog.providerId !== providerId) throw new Error(`catalog providerId does not match '${providerId}'`)
    seenProviders.add(providerId)
    const models = Object.create(null)
    const modelIds = new Set()
    if (!Array.isArray(catalog.models)) throw new Error(`models for '${providerId}' must be an array`)
    for (const model of catalog.models) {
      object(model, `model for '${providerId}'`)
      const modelId = string(model.id, `model id for '${providerId}'`)
      if (modelIds.has(modelId)) throw new Error(`duplicate model '${providerId}/${modelId}'`)
      modelIds.add(modelId)
      const reference = `${providerId}/${modelId}`
      if (modelReferences.has(reference)) throw new Error(`duplicate model '${reference}'`)
      modelReferences.add(reference)
      const contextWindow = model.contextWindow === undefined ? undefined : integer(model.contextWindow, `context window for '${reference}'`)
      const maxOutputTokens = model.maxOutputTokens === undefined ? undefined : integer(model.maxOutputTokens, `output limit for '${reference}'`)
      const neutralCost = optionalCost(model.cost, `cost for '${reference}'`)
      const cost = neutralCost === undefined ? undefined : {
        ...neutralCost,
        ...(neutralCost.cacheRead === undefined ? {} : { cache_read: neutralCost.cacheRead }),
        ...(neutralCost.cacheWrite === undefined ? {} : { cache_write: neutralCost.cacheWrite }),
      }
      delete cost?.cacheRead
      delete cost?.cacheWrite
      const reasoning = optionalReasoning(model.reasoning, `reasoning for '${reference}'`)
      const inputModalities = optionalInputModalities(model.inputModalities, `input modalities for '${reference}'`)
      models[modelId] = {
        name: model.name === undefined ? modelId : string(model.name, `model name for '${reference}'`),
        ...(reasoning === undefined ? {} : { reasoning }),
        ...(inputModalities === undefined ? {} : { modalities: { input: inputModalities } }),
        ...(contextWindow === undefined ? {} : { limit: { context: contextWindow, ...(maxOutputTokens === undefined ? {} : { output: maxOutputTokens }) } }),
        ...(cost === undefined ? {} : { cost: { ...cost, ...(model.costAbove200kContext === undefined ? {} : { context_over_200k: renameToSnakeCase(optionalCost(model.costAbove200kContext, `tiered cost for '${reference}'`)) }) } }),
      }
    }
    const protocol = API_PROTOCOLS[facts.apiProtocol]
    if (!protocol) throw new Error(`unsupported apiProtocol for '${providerId}'`)
    const declaredHost = string(facts.host, `host for '${providerId}'`).toLowerCase()
    const baseUrl = string(facts.baseUrl, `baseUrl for '${providerId}'`)
    if (parseProviderUrl(baseUrl, `baseUrl for '${providerId}'`).hostname.toLowerCase() !== declaredHost) throw new Error(`baseUrl host does not match '${providerId}'`)
    if (parseProviderUrl(facts.modelsUrl, `modelsUrl for '${providerId}'`).hostname.toLowerCase() !== declaredHost) throw new Error(`modelsUrl host does not match '${providerId}'`)
    const keyEnv = string(facts.keyEnv, `keyEnv for '${providerId}'`)
    if (!KEY_ENV.test(keyEnv)) throw new Error(`invalid keyEnv for '${providerId}'`)
    providers[providerId] = {
      npm: protocol.npm,
      name: providerId,
      options: { baseURL: baseUrl, apiKey: `{env:${keyEnv}}`, ...protocol.options },
      models,
    }
    enabled.push(providerId)
    if (catalog.recommendations !== undefined && (catalog.recommendations === null || typeof catalog.recommendations !== "object" || Array.isArray(catalog.recommendations))) {
      throw new Error(`recommendations for '${providerId}' must be an object`)
    }
    for (const [role, modelId] of Object.entries(catalog.recommendations ?? {})) {
      if (!ROLE_PATHS[role]) throw new Error(`unsupported recommendation role '${role}'`)
      string(modelId, `${role} recommendation for '${providerId}'`)
      if (!modelIds.has(modelId)) throw new Error(`dangling ${role} recommendation '${providerId}/${modelId}'`)
      recommendations[role] ??= `${providerId}/${modelId}`
    }
  }

  const config = { enabled_providers: enabled, provider: providers }
  for (const [role, target] of Object.entries(ROLE_PATHS)) {
    if (!recommendations[role]) continue
    let cursor = config
    for (const key of target.slice(0, -1)) cursor = cursor[key] ??= {}
    cursor[target.at(-1)] = recommendations[role]
  }
  return config
}

export async function loadProviderInputs(providerRoot) {
  let directories
  try {
    directories = await readdir(providerRoot, { withFileTypes: true })
  } catch (error) {
    if (error?.code === "ENOENT") return []
    throw error
  }
  const inputs = []
  for (const directory of directories.filter((entry) => entry.isDirectory()).sort((left, right) => left.name.localeCompare(right.name))) {
    const root = path.join(providerRoot, directory.name)
    if (!PROVIDER_ID.test(directory.name)) throw new Error(`invalid provider directory '${directory.name}'`)
    const [factsText, catalogText] = await Promise.all([readFile(path.join(root, "facts.json"), "utf8"), readFile(path.join(root, "snapshot.json"), "utf8")])
    const facts = object(JSON.parse(factsText), `facts for '${directory.name}'`)
    const catalog = object(JSON.parse(catalogText), `snapshot for '${directory.name}'`)
    if (facts.providerId !== directory.name || catalog.providerId !== directory.name) throw new Error(`provider identity does not match directory '${directory.name}'`)
    inputs.push({ facts, catalog })
  }
  return inputs
}

async function existingConfig(globalDir) {
  let merged = {}
  let entries = []
  try {
    entries = new Set(await readdir(globalDir))
  } catch (error) {
    if (error?.code === "ENOENT") return { config: merged, canonicalText: undefined, canonicalConfig: undefined }
    throw error
  }
  for (const name of GLOBAL_FILENAMES) {
    if (entries.has(name)) merged = deepMerge(merged, parseJsonc(await readFile(path.join(globalDir, name), "utf8")))
  }
  const text = await canonicalText(globalDir)
  const canonicalConfig = text === undefined ? undefined : parseJsonc(text)
  return { config: merged, canonicalText: text, canonicalConfig }
}

export async function writeConfigAtomically(globalDir, rendered, ownership = { providers: {}, roles: {} }, options = {}) {
  object(rendered, "rendered provider config")
  validateOwnership(ownership)
  await mkdir(globalDir, { recursive: true })
  const release = await acquireLock(globalDir, options)
  try {
    for (let attempt = 0; attempt < MAX_WRITE_RETRIES; attempt++) {
      const current = await existingConfig(globalDir)
      const state = readEmbeddedState(current.canonicalText, current.config, current.canonicalConfig, ownership)
      const baseConfig = object(options.baseConfig ?? {}, "base OpenCode config")
      const composed = mergeBasePolicy(baseConfig, current.config)
      // Policy is kit-owned: preserving foreign settings must not reopen the
      // credential and outbound-action safeguards staged with this kit.
      const output = mergeManagedConfig(composed, rendered, state, ownership, current.canonicalConfig)
      validateRoleReferences(output.config, "merged OpenCode config", ownership.providers)
      const text = serializeConfig(output.config, output.state)
      await options.beforeReplace?.(attempt)
      // The startup contract has one acq-owned writer. This comparison only
      // detects an unexpected external change before replacement; it does not
      // claim to coordinate or preserve non-cooperating writers.
      if ((await canonicalText(globalDir)) !== current.canonicalText) continue
      await replaceAtomically(globalDir, CANONICAL_FILENAME, text, options)
      return
    }
    throw new Error("OpenCode config changed during every replacement attempt")
  } finally { await release() }
}

function mergeManagedConfig(existing, rendered, state, ownership, canonicalConfig = undefined) {
  const managed = new Set(Object.keys(state.providers))
  // Providers that were previously kit-owned but are absent from the current
  // authoritative render are tombstoned: they must not reappear from stale
  // lower-precedence files (config.json, opencode.json) on the next startup.
  // The tombstone set is: providers that were ever owned (in state.providers OR
  // in state.removed) but are NOT in the new authoritative render's owned set.
  const previouslyRemoved = new Set(state.removed ?? [])
  const newOwned = new Set(Object.keys(ownership.providers))
  const tombstoned = new Set([...managed, ...previouslyRemoved].filter((id) => !newOwned.has(id)))
  // Per-role tombstone history: accumulate all kit-owned values for each role across
  // transitions. A value is stale if it appears in the history for that role, which
  // prevents resurrection of historical defaults from lower-precedence files even after
  // multiple provider switches (e.g. usai→acme→empty: both "usai/..." and "acme/..." are
  // in history and must be suppressed, not just the most recently recorded single value).
  //
  // removedRoles maps role → most-recently-dropped kit value (maintained for serialization
  // compatibility with existing v3 state). removedRoleHistory maps role → sorted array of
  // all kit-owned values ever recorded for that role; any of these appearing in the merged
  // config is stale and must be suppressed.
  const removedRoles = { ...(state.removedRoles ?? {}) }
  const removedRoleHistory = Object.fromEntries(
    Object.entries(state.removedRoleHistory ?? {}).map(([role, refs]) => [role, new Set(Array.isArray(refs) ? refs : [refs])])
  )
  for (const [role, reference] of Object.entries(state.roles)) {
    if (ownership.roles[role] === undefined) {
      // Role dropped: record in both removedRoles (last known) and per-role history.
      removedRoles[role] = reference
      if (!removedRoleHistory[role]) removedRoleHistory[role] = new Set()
      removedRoleHistory[role].add(reference)
    } else if (ownership.roles[role] !== reference) {
      // Role superseded by a different kit value (provider switch): the old value must
      // also be tombstoned so lower-file copies of it cannot resurrect after the new
      // recommendation is later removed.
      if (!removedRoleHistory[role]) removedRoleHistory[role] = new Set()
      removedRoleHistory[role].add(reference)
    }
  }
  const userRoles = Object.fromEntries(Object.entries(ROLE_PATHS)
    .map(([role, keys]) => {
      const current = roleValue(existing, keys)
      // A role value is stale if it appears in the per-role tombstone history (any previously
      // kit-owned value across all provider transitions) OR matches the single removedRoles entry.
      // Exception: if the canonical file (opencode.jsonc) explicitly carries this value AND it
      // differs from the current kit recommendation (state.roles[role]), it is a direct user edit
      // to the canonical file — not a lower-file fallback — and must be treated as a user override
      // regardless of history membership.  Only suppress values that arrive exclusively from
      // lower-precedence files (config.json / opencode.json).
      const canonicalValue = canonicalConfig !== undefined ? roleValue(canonicalConfig, keys) : undefined
      const isCanonicalExplicitEdit = canonicalValue === current && current !== state.roles[role]
      const staleRemoved = current !== undefined && !isCanonicalExplicitEdit && (
        removedRoles[role] === current ||
        (removedRoleHistory[role] !== undefined && removedRoleHistory[role].has(current))
      )
      return [role, current !== undefined && !staleRemoved && (state.roles[role] === undefined || current !== state.roles[role]) ? current : undefined]
    })
    .filter(([, value]) => value !== undefined))
  const provider = { ...(existing.provider ?? {}), ...(rendered.provider ?? {}) }
  // Remove all managed providers (to be replaced by rendered set) and all
  // tombstoned providers (previously owned, now absent from authoritative render).
  for (const id of managed) delete provider[id]
  for (const id of tombstoned) delete provider[id]
  Object.assign(provider, rendered.provider)
  const enabled = (existing.enabled_providers ?? []).filter((id) => !managed.has(id) && !tombstoned.has(id))
  for (const id of rendered.enabled_providers) if (!enabled.includes(id)) enabled.push(id)
  enabled.sort((left, right) => left.localeCompare(right))
  const config = { ...deepMerge(existing, rendered), provider, enabled_providers: enabled }
  for (const [role, keys] of Object.entries(ROLE_PATHS)) {
    let target = config
    for (const key of keys.slice(0, -1)) target = target?.[key]
    const userOverride = Object.prototype.hasOwnProperty.call(userRoles, role)
    if (userOverride) {
      target = config
      for (const key of keys.slice(0, -1)) target = target[key] ??= {}
      target[keys.at(-1)] = userRoles[role]
      continue
    }
    if ((state.roles[role] !== undefined || removedRoles[role] !== undefined) && !userOverride) delete target[keys.at(-1)]
    let source = rendered
    for (const key of keys.slice(0, -1)) source = source?.[key]
    if (source?.[keys.at(-1)] !== undefined && !userOverride) {
      target = config
      for (const key of keys.slice(0, -1)) target = target[key] ??= {}
      target[keys.at(-1)] = source[keys.at(-1)]
    }
  }
  // Record kit-owned roles only for roles that are NOT user overrides. A role
  // whose output value happens to equal the current recommendation must not be
  // reclaimed as kit-owned when the user explicitly selected that value — doing
  // so would cause a future recommendation change to tombstone the user's value
  // into history and silently suppress it on the next render. Kit ownership is
  // only valid when the renderer (not the user) is the authority for that role.
  const roles = {}
  for (const [role, keys] of Object.entries(ROLE_PATHS)) {
    if (Object.prototype.hasOwnProperty.call(userRoles, role)) continue
    let source = rendered
    for (const key of keys) source = source?.[key]
    if (source !== undefined && roleValue(config, keys) === source) roles[role] = source
  }
  for (const role of Object.keys(userRoles)) {
    delete removedRoles[role]
    delete removedRoleHistory[role]
  }
  for (const role of Object.keys(roles)) {
    delete removedRoles[role]
    // Do NOT clear removedRoleHistory here: lower-precedence files may still contain
    // historically kit-owned values for this role that should remain suppressed. Only a
    // genuine user override (in userRoles above) clears the per-role tombstone history.
  }
  const removed = tombstoned.size > 0 ? [...tombstoned].sort() : undefined
  const hasRemovedRoles = Object.keys(removedRoles).length > 0
  // Serialize per-role tombstone history: each role entry is a sorted array of all
  // previously kit-owned values for that role. Only roles that still have history
  // (not cleared by user override or new kit assignment) are persisted.
  const removedRoleHistorySerializable = Object.fromEntries(
    Object.entries(removedRoleHistory)
      .filter(([, refs]) => refs.size > 0)
      .map(([role, refs]) => [role, [...refs].sort()])
  )
  const hasRemovedRoleHistory = Object.keys(removedRoleHistorySerializable).length > 0
  const newState = { schemaVersion: "acq-opencode-provider-state/v3", providers: ownership.providers, roles, ...(removed ? { removed } : {}), ...(hasRemovedRoles ? { removedRoles } : {}), ...(hasRemovedRoleHistory ? { removedRoleHistory: removedRoleHistorySerializable } : {}) }
  return { config, state: newState }
}

export function ownershipFromRendered(rendered) {
  return {
    providers: Object.fromEntries(Object.entries(rendered.provider ?? {}).map(([id, provider]) => [id, digest(provider)])),
    roles: selectedRoles(rendered),
  }
}

function digest(value) {
  return createHash("sha256").update(JSON.stringify(value)).digest("hex")
}

function selectedRoles(config) {
  const roles = {}
  for (const [role, keys] of Object.entries(ROLE_PATHS)) {
    let value = config
    for (const key of keys) value = value?.[key]
    if (value !== undefined) roles[role] = value
  }
  return roles
}

function validateOwnership(state) {
  object(state.providers, "provider ownership")
  for (const [id, providerDigest] of Object.entries(state.providers)) {
    if (!PROVIDER_ID.test(id) || !/^[a-f0-9]{64}$/.test(providerDigest)) throw new Error("invalid provider ownership")
  }
  object(state.roles, "provider ownership roles")
  for (const [role, reference] of Object.entries(state.roles)) {
    if (!ROLE_PATHS[role] || typeof reference !== "string") throw new Error("invalid provider ownership role")
  }
  if (state.removed !== undefined) {
    if (!Array.isArray(state.removed)) throw new Error("invalid provider ownership removed list")
    for (const id of state.removed) {
      if (!PROVIDER_ID.test(id)) throw new Error("invalid provider ownership removed entry")
    }
  }
  if (state.removedRoles !== undefined) {
    object(state.removedRoles, "provider ownership removed roles")
    for (const [role, reference] of Object.entries(state.removedRoles)) {
      if (!ROLE_PATHS[role] || typeof reference !== "string") throw new Error("invalid provider ownership removed role")
    }
  }
  if (state.removedRoleHistory !== undefined) {
    object(state.removedRoleHistory, "provider ownership removed role history")
    for (const [role, refs] of Object.entries(state.removedRoleHistory)) {
      if (!ROLE_PATHS[role] || !Array.isArray(refs)) throw new Error("invalid provider ownership removed role history entry")
      for (const ref of refs) {
        if (typeof ref !== "string") throw new Error("invalid provider ownership removed role history reference")
      }
    }
  }
}

function statePayload(state) {
  return Buffer.from(JSON.stringify(state)).toString("base64url")
}

function serializeConfig(config, state) {
  const body = JSON.stringify(config, null, 2) + "\n"
  object(JSON.parse(body), "generated OpenCode config")
  return `${STATE_COMMENT}${statePayload(state)}\n${body}`
}

function generatedProvider(value) {
  return value && typeof value === "object" && value.npm === "@ai-sdk/openai-compatible" && typeof value.options?.baseURL === "string" && typeof value.options?.apiKey === "string"
}

function readEmbeddedState(text, config, canonicalConfig, expectedOwnership) {
  // Finding 2 fix: when canonical opencode.jsonc is absent, still run legacy
  // recognition against the composed merged configuration (which includes
  // lower-precedence config.json / opencode.json). An absent canonical is not
  // "no config at all" — the merged config may contain a fingerprint-matched
  // legacy block that must be claimed and migrated on this first render.
  const effectiveText = text === undefined ? "" : text
  const line = effectiveText.split("\n", 1)[0]
  if (!line.startsWith(STATE_COMMENT)) {
    const expected = expectedOwnership?.providers ?? {}
    const provider = config.provider ?? {}
    const ids = Object.keys(expected)
    // The sole metadata-free migration accepts only a complete, byte-equivalent
    // generated provider set. Any addition, removal, or semantic edit is
    // ambiguous user state and remains fail-closed.
    if (ids.length > 0 && ids.length === Object.keys(provider).length && ids.every((id) => Object.prototype.hasOwnProperty.call(provider, id) && digest(provider[id]) === expected[id])) {
      return {
        providers: expected,
        roles: Object.fromEntries(Object.entries(expectedOwnership.roles ?? {})
          .filter(([role, reference]) => roleValue(config, ROLE_PATHS[role]) === reference)),
      }
    }
    // Legacy cutover: recognize previously shipped provider blocks whose exact
    // digest matches a committed fingerprint. Detection is provider-ID-independent —
    // each block in the existing config is checked against the fingerprint map.
    // Only exact committed shapes pass; any user or provider edit falls through
    // to the fail-closed path. This path fires exactly once per provider: on the
    // first render after upgrading from a kit that wrote the config without state
    // metadata. Subsequent renders carry state.
    const legacyMatches = Object.entries(provider)
      .filter(([, block]) => generatedProvider(block) && LEGACY_PROVIDER_FINGERPRINT_MAP.has(digest(block)))
    if (legacyMatches.length > 0) {
      const legacyProviders = Object.fromEntries(legacyMatches.map(([id, block]) => [id, digest(block)]))
      const legacyIdSet = new Set(Object.keys(legacyProviders))
      // Any provider block not covered by the legacy set that still looks auto-generated
      // is ambiguous state — fail closed rather than silently passing it through.
      if (Object.entries(provider).some(([id, block]) => !legacyIdSet.has(id) && generatedProvider(block))) throw new Error("generated provider config has no trustworthy ownership metadata")
      // Claim only roles whose current value EXACTLY equals the historically shipped
      // default for that fingerprint. Any deviation — even a different model on the
      // same legacy provider — is a user selection and must remain unowned/preserved.
      const legacyRoles = Object.fromEntries(
        Object.entries(ROLE_PATHS)
          .flatMap(([role, keys]) => {
            const current = roleValue(config, keys)
            if (typeof current !== "string") return []
            // Look up the shipped default for this role across all matched legacy blocks.
            for (const [, block] of legacyMatches) {
              const shippedRoles = LEGACY_PROVIDER_FINGERPRINT_MAP.get(digest(block))
              if (shippedRoles?.[role] === current) return [[role, current]]
            }
            return []
          })
      )
      return { providers: legacyProviders, roles: legacyRoles }
    }
    if (Object.values(provider).some(generatedProvider)) throw new Error("generated provider config has no trustworthy ownership metadata")
    return { providers: {}, roles: {} }
  }
  let state
  try { state = JSON.parse(Buffer.from(line.slice(STATE_COMMENT.length), "base64url").toString("utf8")) } catch { throw new Error("malformed provider ownership metadata") }
  if (state.schemaVersion !== "acq-opencode-provider-state/v3") throw new Error("incompatible provider ownership metadata")
  validateOwnership(state)
  // Finding 2 fix: validate ownership digests against the CANONICAL config's provider blocks,
  // not the merged (canonical + lower-file) config. Lower-precedence files (config.json,
  // opencode.json) may retain stale versions of previously rendered provider blocks (e.g.
  // a catalog shrink from a,b→a), and deepMerge is additive — it would reintroduce deleted
  // models from lower files, making the merged block's digest differ from the state digest.
  // The canonical opencode.jsonc is the sole authoritative written artifact; ownership only
  // needs to verify what the kit actually wrote last time, not what lower files may have
  // contributed.
  const ownedProviderSource = canonicalConfig?.provider ?? config.provider ?? {}
  for (const [id, providerDigest] of Object.entries(state.providers)) {
    if (!Object.prototype.hasOwnProperty.call(ownedProviderSource, id) || !generatedProvider(ownedProviderSource[id]) || digest(ownedProviderSource[id]) !== providerDigest) throw new Error(`owned provider '${id}' is missing or was modified`)
  }
  return state
}

function roleValue(config, keys) {
  let value = config
  for (const key of keys) value = value?.[key]
  return value
}

function validateRoleReferences(config, label, managedProviders = {}) {
  const provider = config.provider === undefined ? {} : object(config.provider, `${label} provider`)
  for (const [role, keys] of Object.entries(ROLE_PATHS)) {
    const reference = roleValue(config, keys)
    if (reference === undefined) continue
    if (typeof reference !== "string") throw new Error(`${label} ${role} default must be a string`)
    const slash = reference.indexOf("/")
    const providerId = reference.slice(0, slash)
    const modelId = reference.slice(slash + 1)
    // Only validate references that point to a managed (kit-generated) provider.
    // Built-in or user-configured providers (anthropic, openai, etc.) are unowned
    // by the renderer and must pass through without validation errors.
    // A reference to a managed provider that is absent or missing the model is
    // still a hard failure (dangling managed reference).
    if (!Object.prototype.hasOwnProperty.call(managedProviders, providerId)) continue
    if (slash < 1 || !Object.prototype.hasOwnProperty.call(provider, providerId) || !provider[providerId].models || !Object.prototype.hasOwnProperty.call(provider[providerId].models, modelId)) throw new Error(`${label} has dangling ${role} default '${reference}'`)
  }
}

async function canonicalText(globalDir) {
  try { return await readFile(path.join(globalDir, CANONICAL_FILENAME), "utf8") } catch (error) { if (error?.code === "ENOENT") return undefined; throw error }
}

async function replaceAtomically(globalDir, filename, text, options = {}) {
  const temporary = path.join(globalDir, `.${filename}.${process.pid}.${randomBytes(16).toString("hex")}.tmp`)
  try {
    const file = await open(temporary, "wx", 0o600)
    try { await file.writeFile(text); await file.sync() } finally { await file.close() }
    await options.beforeRename?.()
    await rename(temporary, path.join(globalDir, filename))
    const directory = await open(globalDir, "r")
    try { await directory.sync() } finally { await directory.close() }
  } catch (error) {
    await rm(temporary, { force: true })
    throw error
  }
}

async function acquireLock(globalDir, options = {}) {
  const lock = path.join(globalDir, LOCK_FILENAME)
  const host = options.hostname ?? os.hostname()
  const startTime = options.processStartTime ?? processStartTime
  const owner = JSON.stringify({ schemaVersion: "acq-opencode-provider-lock/v3", pid: process.pid, host, startTime: await startTime(process.pid), nonce: randomBytes(16).toString("hex") })
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      await readFile(`${lock}.recovery`, "utf8")
      await new Promise((resolve) => setTimeout(resolve, 10))
      continue
    } catch (error) { if (error?.code !== "ENOENT") throw error }
    try {
      await writeFile(lock, owner, { mode: 0o600, flag: "wx" })
      return async () => releaseLock(lock, owner)
    } catch (error) {
      if (error?.code !== "EEXIST") throw error
      const stale = await staleLock(lock, host, { ...options, processStartTime: startTime })
      if (stale) continue
      await new Promise((resolve) => setTimeout(resolve, 10))
    }
  }
  throw new Error(`timed out waiting for provider config lock at ${lock}; inspect the lock file for the active owner`)
}

async function staleLock(lock, host, options) {
  const recovery = `${lock}.recovery`
  const recoveryOwner = JSON.stringify({ pid: process.pid, host, nonce: randomBytes(16).toString("hex") })
  try {
    await writeFile(recovery, recoveryOwner, { mode: 0o600, flag: "wx" })
  } catch (error) {
    if (error?.code === "EEXIST") return false
    throw error
  }
  try {
  let owner
  try { owner = JSON.parse(await readFile(lock, "utf8")) } catch (error) {
    if (error?.code === "ENOENT") return false
    throw new Error(`provider config lock at ${lock} has no readable owner identity; refusing to steal it`)
  }
  if (owner.schemaVersion !== "acq-opencode-provider-lock/v3" || owner.host !== host || !Number.isSafeInteger(owner.pid) || owner.pid < 1 || typeof owner.startTime !== "string" || typeof owner.nonce !== "string") {
    throw new Error(`provider config lock at ${lock} has an untrusted owner identity; refusing to steal it`)
  }
  const alive = options.isProcessAlive ?? ((pid) => {
    try { process.kill(pid, 0); return true } catch (error) { if (error?.code === "ESRCH") return false; if (error?.code === "EPERM") return true; throw error }
  })
  const startTime = options.processStartTime ?? processStartTime
  if (await alive(owner.pid) && await startTime(owner.pid) === owner.startTime) return false
  try {
    // Every acquisition observes this recovery sentinel before creating the
    // primary lock. Once held, no replacement lock can race this unlink.
    if (await readFile(lock, "utf8") !== JSON.stringify(owner)) return false
    await unlink(lock)
    return true
  } catch (error) {
    if (error?.code === "ENOENT") return false
    throw error
  }
  } finally {
    try { if (await readFile(recovery, "utf8") === recoveryOwner) await unlink(recovery) } catch (error) { if (error?.code !== "ENOENT") throw error }
  }
}

async function releaseLock(lock, owner) {
  try {
    if (await readFile(lock, "utf8") !== owner) return
    await unlink(lock)
  } catch (error) { if (error?.code !== "ENOENT") throw error }
}

async function processStartTime(pid) {
  try {
    const fields = (await readFile(`/proc/${pid}/stat`, "utf8")).trim().split(" ")
    return fields[21] ?? "unavailable"
  } catch (error) {
    if (error?.code === "ENOENT") return "missing"
    return "unavailable"
  }
}

export async function applyProviderProjection(providerRoot, globalDir, options = {}) {
  // The backend materializes the authoritative provider directories directly
  // below its read-only input root. A missing root is not an empty set and
  // therefore deliberately leaves the existing config untouched.
  const current = path.join(providerRoot, "models", "providers")
  let inputs
  try {
    await readdir(current)
    inputs = await loadProviderInputs(current)
  } catch (error) {
    if (error?.code === "ENOENT") return "not-ready"
    throw error
  }
  const rendered = renderProviderConfig(inputs)
  const baseConfig = options.baseConfig ?? parseJsonc(await readFile(options.baseConfigPath ?? "/home/agent/opencode-config/base-config.jsonc", "utf8"))
  await writeConfigAtomically(globalDir, rendered, ownershipFromRendered(rendered), { ...options, baseConfig })
  return "authoritative"
}

function argument(name, fallback) {
  const index = process.argv.indexOf(name)
  return index === -1 ? fallback : process.argv[index + 1]
}

// Compare URL against URL so the check is portable: on Windows
// `process.argv[1]` is a `C:\...` path, which a `file://${...}` template turns
// into `file://C:\...`, while `import.meta.url` is `file:///C:/...`. Those never
// match, so this script would exit 0 without doing anything.
if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  const providerRoot = argument("--provider-root", process.env.ACQ_PROVIDER_INPUT_ROOT ?? "/var/lib/acq/provider-input")
  const globalDir = argument("--global-dir", path.join(process.env.HOME ?? "/home/agent", ".config/opencode"))
  const baseConfigPath = argument("--base-config", "/home/agent/opencode-config/base-config.jsonc")
  applyProviderProjection(providerRoot, globalDir, { baseConfigPath }).catch((error) => {
    console.error(`opencode-config: ${error.message}`)
    process.exit(1)
  })
}
