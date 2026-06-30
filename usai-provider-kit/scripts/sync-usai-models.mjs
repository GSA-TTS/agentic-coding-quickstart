#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

// Anchor all default paths at the kit root (this file lives in <kit>/scripts/),
// so the script works regardless of the caller's working directory.
const KIT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..")

const GENERATED_START = "// BEGIN GENERATED USAI MODELS"
const GENERATED_END = "// END GENERATED USAI MODELS"

// Vendor ordering and labels for grouped output
const VENDOR_CONFIG = {
  anthropic: { order: 1, label: "Anthropic Models" },
  openai: { order: 2, label: "OpenAI Models" },
  google: { order: 3, label: "Google Models" },
  meta: { order: 4, label: "Meta Models" },
  cohere: { order: 5, label: "Cohere Models" },
  other: { order: 99, label: "Other Models" },
}

// Special display name overrides for complex model IDs
const DISPLAY_NAME_OVERRIDES = {
  "gpt-5.4-latest-guardrails-defaultv2": "GPT-5.4 Latest — Guardrails Default v2",
  "gpt-5.2-latest-guardrails-defaultv2": "GPT-5.2 Latest — Guardrails Default v2",
  cohere_english_v3: "Cohere English v3",
}

const DEFAULT_TEMPLATE_PATH = path.join(KIT_ROOT, "files/home/usai-config/opencode.jsonc")
const DEFAULT_FIXTURE_PATH = path.join(KIT_ROOT, "tests/fixtures/usai-models.json")
const MODELS_DEV_URL = "https://models.dev/models.json"
const USAI_MODELS_URL = "https://api.gsa.usai.gov/api/v1/models"

// Network hardening limits (Issue #138). Remote feeds (USAi API, models.dev)
// are third-party content written into committed config, so we bound time and
// size and validate the shape before trusting the response.
const FETCH_TIMEOUT_MS = 15000
const MAX_RESPONSE_BYTES = 10 * 1024 * 1024 // 10 MiB

// Fallback limits for models not found in models.dev
const FALLBACK_LIMITS = {
  context: 128000,
  output: 8192,
}

function normalizeText(value) {
  return String(value ?? "").toLowerCase()
}

function extractParts(text) {
  return normalizeText(text)
    .replace(/[^a-z0-9]+/g, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
}

function parseVersion(text) {
  const normalized = normalizeText(text)
  const match = normalized.match(/(\d+)(?:[._-](\d+))?(?:[._-](\d+))?/)
  if (!match) {
    return [0, 0, 0]
  }

  return [
    Number.parseInt(match[1] || "0", 10),
    Number.parseInt(match[2] || "0", 10),
    Number.parseInt(match[3] || "0", 10),
  ]
}

function compareVersions(a, b) {
  for (let i = 0; i < Math.max(a.length, b.length); i += 1) {
    const left = a[i] || 0
    const right = b[i] || 0
    if (left !== right) {
      return left - right
    }
  }

  return 0
}

function parseModel(rawModel) {
  const id = rawModel.id || rawModel.model_id || rawModel.name
  const name = rawModel.name || rawModel.display_name || id
  const ownedBy = normalizeText(rawModel.owned_by || "")
  const haystack = `${id} ${name}`
  const parts = extractParts(haystack)
  const version = parseVersion(haystack)
  const isEmbedding = /embedding|embed/.test(haystack)
  const isPreview = /preview|beta|experimental/.test(haystack)
  const isMini = /mini/.test(haystack)
  const isNano = /nano/.test(haystack)
  const isFlashLite = /flash lite|flash-lite/.test(haystack)
  const isChat = !isEmbedding

  // Determine vendor from owned_by or model ID
  let vendor = "other"
  if (ownedBy.includes("anthropic") || /^claude/i.test(id)) {
    vendor = "anthropic"
  } else if (ownedBy.includes("open ai") || ownedBy.includes("openai") || /^gpt/i.test(id)) {
    vendor = "openai"
  } else if (ownedBy.includes("google") || /^gemini/i.test(id)) {
    vendor = "google"
  } else if (ownedBy.includes("meta") || /^llama/i.test(id)) {
    vendor = "meta"
  } else if (ownedBy.includes("cohere") || /^cohere/i.test(id)) {
    vendor = "cohere"
  }

  return {
    id,
    name,
    vendor,
    raw: rawModel,
    parts,
    version,
    isEmbedding,
    isPreview,
    isMini,
    isNano,
    isFlashLite,
    isChat,
    contextWindow: rawModel.context_window || rawModel.contextWindow || rawModel.context || null,
    maxOutputTokens: rawModel.max_output_tokens || rawModel.maxOutputTokens || rawModel.output || null,
  }
}

function isAllowedModel(model) {
  return model.isChat
}

/**
 * Generate a human-readable display name from a model ID.
 * @param {string} id - Model ID
 * @returns {string} Human-readable display name
 */
function generateDisplayName(id) {
  // Check for special overrides first
  if (DISPLAY_NAME_OVERRIDES[id]) {
    return DISPLAY_NAME_OVERRIDES[id]
  }

  // General transformation
  return id
    .replace(/[_-]+/g, " ") // Replace underscores/hyphens with spaces
    .replace(/(\d)\s+(\d)/g, "$1.$2") // "4 5" -> "4.5"
    .replace(/\b\w/g, (c) => c.toUpperCase()) // Capitalize words
    .replace(/\bGpt\b/g, "GPT") // Fix GPT
    .replace(/\bLlama\b/g, "Llama") // Keep Llama
}

/**
 * Sort models by vendor order, then by version (descending).
 * @param {Array} models - Array of parsed models
 * @returns {Array} Sorted models
 */
function sortModelsByVendor(models) {
  return [...models].sort((a, b) => {
    const vendorA = VENDOR_CONFIG[a.vendor]?.order ?? 99
    const vendorB = VENDOR_CONFIG[b.vendor]?.order ?? 99
    if (vendorA !== vendorB) return vendorA - vendorB

    // Within vendor, sort by version descending then alphabetically
    const versionCmp = compareVersions(b.version, a.version)
    if (versionCmp !== 0) return versionCmp

    return a.id.localeCompare(b.id)
  })
}

/**
 * Normalize a model ID for fuzzy matching.
 * Handles differences like underscores vs hyphens, version formats, etc.
 * @param {string} id - Model ID to normalize
 * @returns {string} Normalized ID for comparison
 */
function normalizeModelId(id) {
  // Strip provider prefix if present (e.g., "anthropic/claude-4" -> "claude-4")
  const withoutProvider = id.includes("/") ? id.split("/").pop() : id
  return withoutProvider
    .toLowerCase()
    .replace(/[_-]+/g, "-")
    .replace(/(\d)\.(\d)/g, "$1-$2") // 4.5 -> 4-5
    .replace(/guardrails.*$/i, "") // Remove USAI-specific suffixes
    .replace(/latest.*$/i, "")
    .replace(/-+$/, "")
}

/**
 * Extract family and version tokens from a model ID.
 * @param {string} id - Model ID
 * @returns {{ family: string, version: number[], variant: string }}
 */
function extractModelTokens(id) {
  const normalized = normalizeModelId(id)
  const parts = normalized.split("-")

  // Identify family (claude, gpt, gemini, llama, cohere)
  let family = ""
  let variant = ""
  const versionParts = []

  for (const part of parts) {
    if (/^(claude|gpt|gemini|llama|cohere)$/i.test(part)) {
      family = part
    } else if (/^(opus|sonnet|haiku|pro|flash|mini|nano|maverick)$/i.test(part)) {
      variant = part
    } else if (/^\d+$/.test(part)) {
      versionParts.push(Number.parseInt(part, 10))
    }
  }

  return { family, version: versionParts, variant }
}

/**
 * Find the best matching model in models.dev catalog for a USAI model ID.
 * @param {string} usaiId - USAI model ID (e.g., "claude_4_5_opus")
 * @param {Object} catalog - models.dev catalog keyed by model ID
 * @returns {{ id: string, data: Object } | null}
 */
function findModelsDevMatch(usaiId, catalog) {
  const usaiTokens = extractModelTokens(usaiId)

  // Score each catalog entry
  let bestMatch = null
  let bestScore = 0

  for (const [catalogId, data] of Object.entries(catalog)) {
    const catalogTokens = extractModelTokens(catalogId)

    // Must match family
    if (usaiTokens.family !== catalogTokens.family) continue

    let score = 10 // Base score for family match

    // Variant match (opus, sonnet, haiku, pro, flash, etc.)
    if (usaiTokens.variant && usaiTokens.variant === catalogTokens.variant) {
      score += 50
    }

    // Version match
    const versionMatch = usaiTokens.version.every((v, i) => catalogTokens.version[i] === v)
    if (versionMatch && usaiTokens.version.length > 0) {
      score += 30
    }

    // Prefer exact ID prefix match
    if (normalizeModelId(catalogId).startsWith(normalizeModelId(usaiId).slice(0, 10))) {
      score += 5
    }

    if (score > bestScore) {
      bestScore = score
      bestMatch = { id: catalogId, data }
    }
  }

  return bestMatch
}

/**
 * Fetch with a timeout and a hard response-size cap. Remote feeds are
 * untrusted third-party content, so we never read an unbounded body and we
 * always bound the request time. (Issue #138)
 * @param {string} url
 * @param {object} [options] - fetch options
 * @returns {Promise<unknown>} parsed JSON
 */
async function fetchJsonBounded(url, options = {}) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), options.timeoutMs ?? FETCH_TIMEOUT_MS)

  let response
  try {
    response = await fetch(url, { ...options, signal: controller.signal })
  } catch (err) {
    if (err.name === "AbortError") {
      throw new Error(`request to ${url} timed out after ${FETCH_TIMEOUT_MS}ms`)
    }
    throw err
  } finally {
    clearTimeout(timer)
  }

  if (!response.ok) {
    const body = await response.text().catch(() => "(no body)")
    throw new Error(`request to ${url} failed: ${response.status} ${response.statusText} - ${body.slice(0, 200)}`)
  }

  // Reject obviously-oversized payloads up front when the server advertises a
  // length; otherwise enforce the cap while streaming the body.
  const declaredLength = Number(response.headers.get("content-length") || "0")
  if (declaredLength > MAX_RESPONSE_BYTES) {
    throw new Error(`response from ${url} too large: ${declaredLength} bytes > ${MAX_RESPONSE_BYTES}`)
  }

  const text = await readBodyCapped(response, url)
  try {
    return JSON.parse(text)
  } catch (err) {
    throw new Error(`response from ${url} was not valid JSON: ${err.message}`)
  }
}

/**
 * Read a Response body, aborting if it exceeds MAX_RESPONSE_BYTES.
 * @param {Response} response
 * @param {string} url
 * @returns {Promise<string>}
 */
async function readBodyCapped(response, url) {
  if (!response.body || typeof response.body.getReader !== "function") {
    // Environments without a streaming body (e.g. some test doubles): fall
    // back to text() but still enforce the byte cap afterwards.
    const text = await response.text()
    if (Buffer.byteLength(text, "utf8") > MAX_RESPONSE_BYTES) {
      throw new Error(`response from ${url} exceeded ${MAX_RESPONSE_BYTES} bytes`)
    }
    return text
  }

  const reader = response.body.getReader()
  const chunks = []
  let total = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > MAX_RESPONSE_BYTES) {
      await reader.cancel().catch(() => {})
      throw new Error(`response from ${url} exceeded ${MAX_RESPONSE_BYTES} bytes`)
    }
    chunks.push(value)
  }
  return Buffer.concat(chunks.map((c) => Buffer.from(c))).toString("utf8")
}

/**
 * Validate that a USAi models payload has the expected shape before we trust
 * it enough to rewrite committed config. Accepts a top-level array, or an
 * object with a `data` or `models` array. (Issue #138)
 * @param {unknown} payload
 * @returns {unknown} the same payload (for chaining)
 */
function validateUsaiPayload(payload) {
  const list = Array.isArray(payload)
    ? payload
    : Array.isArray(payload?.data)
      ? payload.data
      : Array.isArray(payload?.models)
        ? payload.models
        : null

  if (!list) {
    throw new Error("USAi payload invalid: expected an array or { data | models: [] }")
  }
  if (list.length === 0) {
    throw new Error("USAi payload invalid: model list is empty")
  }
  const hasUsableId = list.some(
    (m) => m && typeof m === "object" && (m.id || m.model_id || m.name),
  )
  if (!hasUsableId) {
    throw new Error("USAi payload invalid: no entries have an id/model_id/name field")
  }
  return payload
}

export { validateUsaiPayload, fetchJsonBounded }

/**
 * Fetch and parse the models.dev catalog.
 * @returns {Promise<Object>} Catalog keyed by model ID
 */
async function fetchModelsDevCatalog() {
  try {
    const catalog = await fetchJsonBounded(MODELS_DEV_URL)
    // models.dev returns an object keyed by id; reject anything else rather
    // than feeding a malformed catalog into the enrichment matcher.
    if (!catalog || typeof catalog !== "object" || Array.isArray(catalog)) {
      console.error("models.dev catalog has unexpected shape; skipping enrichment")
      return {}
    }
    return catalog
  } catch (err) {
    console.error(`models.dev fetch error: ${err.message}`)
    return {}
  }
}

/**
 * Enrich USAI models with metadata from models.dev.
 * @param {Array} models - Parsed USAI models
 * @param {Object} catalog - models.dev catalog
 * @returns {Array} Enriched models
 */
function enrichModelsFromCatalog(models, catalog) {
  return models.map((model) => {
    const match = findModelsDevMatch(model.id, catalog)

    if (match && match.data.limit) {
      return {
        ...model,
        contextWindow: model.contextWindow || match.data.limit.context || FALLBACK_LIMITS.context,
        maxOutputTokens: model.maxOutputTokens || match.data.limit.output || FALLBACK_LIMITS.output,
        toolCall: match.data.tool_call,
        reasoning: match.data.reasoning,
        modelsDevId: match.id,
      }
    }

    // No match found - use fallbacks
    return {
      ...model,
      contextWindow: model.contextWindow || FALLBACK_LIMITS.context,
      maxOutputTokens: model.maxOutputTokens || FALLBACK_LIMITS.output,
      modelsDevId: null,
    }
  })
}

function familyScore(model, family) {
  if (family === "opus") {
    if (model.parts.includes("opus")) return 1000
    if (model.parts.includes("sonnet")) return 500
    return 0
  }

  if (family === "gpt") {
    return model.parts.includes("gpt") ? 1000 : 0
  }

  if (family === "small") {
    if (model.parts.includes("haiku")) return 1000
    if (model.isMini) return 750
    if (model.isNano) return 700
    if (model.isFlashLite) return 650
    if (model.parts.includes("flash")) return 600
    return 0
  }

  return 0
}

function compareForRole(left, right, family) {
  const familyDelta = familyScore(left, family) - familyScore(right, family)
  if (familyDelta !== 0) {
    return familyDelta
  }

  const versionDelta = compareVersions(left.version, right.version)
  if (versionDelta !== 0) {
    return versionDelta
  }

  const sizePenaltyLeft = Number(left.isMini) + Number(left.isNano) + Number(left.isFlashLite)
  const sizePenaltyRight = Number(right.isMini) + Number(right.isNano) + Number(right.isFlashLite)
  if (sizePenaltyLeft !== sizePenaltyRight) {
    return sizePenaltyRight - sizePenaltyLeft
  }

  if (left.isPreview !== right.isPreview) {
    return Number(right.isPreview) - Number(left.isPreview)
  }

  return right.id.localeCompare(left.id)
}

function selectDefault(models, family, fallbackId) {
  const ranked = [...models].sort((a, b) => compareForRole(b, a, family))
  const selected = ranked.find((model) => familyScore(model, family) > 0)
  return selected ? `usai/${selected.id}` : fallbackId
}

function renderModelBlock(models, eol) {
  const lines = []
  const sortedModels = sortModelsByVendor(models)
  let currentVendor = null

  sortedModels.forEach((model, index) => {
    // Add vendor comment header when vendor changes
    if (model.vendor !== currentVendor) {
      if (currentVendor !== null) {
        // Add blank line between vendor groups
        lines.push("")
      }
      const vendorLabel = VENDOR_CONFIG[model.vendor]?.label || "Other Models"
      lines.push(`        // ${vendorLabel}`)
      currentVendor = model.vendor
    }

    // Generate display name
    const displayName = generateDisplayName(model.id)

    lines.push(`        "${model.id}": {`)
    lines.push(`          "name": "${displayName}",`)

    if (model.contextWindow || model.maxOutputTokens) {
      lines.push('          "limit": {')
      if (model.contextWindow) {
        lines.push(`            "context": ${model.contextWindow}${model.maxOutputTokens ? "," : ""}`)
      }
      if (model.maxOutputTokens) {
        lines.push(`            "output": ${model.maxOutputTokens}`)
      }
      lines.push("          }")
    } else {
      lines.push('          "limit": {}')
    }

    lines.push("        },")
  })

  // Remove trailing comma from last model entry
  if (sortedModels.length > 0) {
    const lastModelLine = lines.findLastIndex((line) => line.trim() === "},")
    if (lastModelLine !== -1) {
      lines[lastModelLine] = "        }"
    }
  }

  return lines.join(eol)
}

function replaceBetween(text, startMarker, endMarker, replacement, eol) {
  const start = text.indexOf(startMarker)
  const end = text.indexOf(endMarker)
  if (start === -1 || end === -1 || end <= start) {
    throw new Error("Generated section markers not found in template")
  }

  const before = text.slice(0, start + startMarker.length)
  const after = text.slice(end)
  return `${before}${eol}${replacement}${eol}        ${after}`
}

function replaceJsonString(text, key, value) {
  const pattern = new RegExp(`("${key}"\\s*:\\s*")([^"]+)(")`)
  if (!pattern.test(text)) {
    throw new Error(`Could not find JSON string for key: ${key}`)
  }
  return text.replace(pattern, `$1${value}$3`)
}

function replaceCompactionModel(text, value) {
  const pattern = /("compaction"\s*:\s*\{[\s\S]*?"model"\s*:\s*")([^"]+)(")/
  if (!pattern.test(text)) {
    throw new Error("Could not find compaction model in template")
  }
  return text.replace(pattern, `$1${value}$3`)
}

export function updateTemplate(templateText, payload, modelsDevCatalog = {}) {
  const eol = templateText.includes("\r\n") ? "\r\n" : "\n"
  const rawModels = Array.isArray(payload)
    ? payload
    : Array.isArray(payload.data)
      ? payload.data
      : Array.isArray(payload.models)
        ? payload.models
        : []

  let models = rawModels
    .map(parseModel)
    .filter((model) => model.id)
    .filter(isAllowedModel)
    .sort((a, b) => a.id.localeCompare(b.id))

  // Enrich with models.dev metadata if catalog provided
  if (Object.keys(modelsDevCatalog).length > 0) {
    models = enrichModelsFromCatalog(models, modelsDevCatalog)
  }

  const updatedBlock = renderModelBlock(models, eol)
  let updatedTemplate = replaceBetween(templateText, GENERATED_START, GENERATED_END, updatedBlock, eol)

  updatedTemplate = replaceJsonString(
    updatedTemplate,
    "model",
    selectDefault(models, "opus", "usai/claude_4_5_opus"),
  )
  updatedTemplate = replaceJsonString(
    updatedTemplate,
    "small_model",
    selectDefault(models, "small", "usai/claude_3_5_haiku"),
  )
  updatedTemplate = replaceCompactionModel(
    updatedTemplate,
    selectDefault(models, "gpt", "usai/gpt-5.4-latest-guardrails-defaultv2"),
  )

  return {
    updatedTemplate,
    models,
  }
}

async function loadPayload(args) {
  const fixtureArg = args.find((arg) => arg.startsWith("--fixture="))
  const fixturePath = fixtureArg ? path.resolve(fixtureArg.split("=")[1]) : DEFAULT_FIXTURE_PATH
  const useFixture = args.includes("--fixture") || Boolean(fixtureArg)

  if (useFixture) {
    return validateUsaiPayload(JSON.parse(await readFile(fixturePath, "utf8")))
  }

  if (!process.env.USAI_API_KEY) {
    throw new Error(
      "USAI_API_KEY is not set. Export it (e.g. `export USAI_API_KEY=...`) and " +
        "re-run, or pass --fixture to sync from the bundled test fixture.",
    )
  }

  let payload
  try {
    payload = await fetchJsonBounded(USAI_MODELS_URL, {
      headers: {
        accept: "application/json",
        authorization: `Bearer ${process.env.USAI_API_KEY}`,
      },
    })
  } catch (err) {
    throw new Error(`USAI API fetch failed: ${err.message}`)
  }

  return validateUsaiPayload(payload)
}

async function main() {
  const args = process.argv.slice(2)
  const checkOnly = args.includes("--check")
  const writeSnapshot = args.includes("--write-snapshot")
  const skipEnrich = args.includes("--skip-enrich")
  const templatePathArg = args.find((arg) => arg.startsWith("--template="))
  const templatePath = templatePathArg ? path.resolve(templatePathArg.split("=")[1]) : DEFAULT_TEMPLATE_PATH

  // Fetch models.dev catalog in parallel with other data (unless skipped)
  const [templateText, payload, modelsDevCatalog] = await Promise.all([
    readFile(templatePath, "utf8"),
    loadPayload(args),
    skipEnrich ? {} : fetchModelsDevCatalog(),
  ])

  const { updatedTemplate, models } = updateTemplate(templateText, payload, modelsDevCatalog)

  // Log enrichment results
  const enriched = models.filter((m) => m.modelsDevId)
  const notEnriched = models.filter((m) => !m.modelsDevId)
  if (enriched.length > 0) {
    process.stdout.write(`Enriched ${enriched.length} models from models.dev\n`)
  }
  if (notEnriched.length > 0) {
    process.stdout.write(`Using fallback limits for ${notEnriched.length} models: ${notEnriched.map((m) => m.id).join(", ")}\n`)
  }

  if (checkOnly) {
    if (templateText !== updatedTemplate) {
      throw new Error("Template is out of date with the current model payload")
    }
    return
  }

  await writeFile(templatePath, updatedTemplate)

  if (writeSnapshot) {
    const snapshotPath = path.join(KIT_ROOT, "tests/output/latest-opencode.jsonc")
    await mkdir(path.dirname(snapshotPath), { recursive: true })
    await writeFile(snapshotPath, updatedTemplate)
  }

  process.stdout.write(`Updated ${templatePath} with ${models.length} models\n`)
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((error) => {
    console.error(error.message)
    process.exit(1)
  })
}
