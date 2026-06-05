#!/usr/bin/env node

import { mkdir, readFile, writeFile } from "node:fs/promises"
import path from "node:path"
import process from "node:process"

const GENERATED_START = "// BEGIN GENERATED USAI MODELS"
const GENERATED_END = "// END GENERATED USAI MODELS"

const DEFAULT_TEMPLATE_PATH = path.resolve("templates/opencode.jsonc")
const DEFAULT_FIXTURE_PATH = path.resolve("tests/fixtures/usai-models.json")

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
  const haystack = `${id} ${name}`
  const parts = extractParts(haystack)
  const version = parseVersion(haystack)
  const isEmbedding = /embedding|embed/.test(haystack)
  const isPreview = /preview|beta|experimental/.test(haystack)
  const isMini = /mini/.test(haystack)
  const isNano = /nano/.test(haystack)
  const isFlashLite = /flash lite|flash-lite/.test(haystack)
  const isChat = !isEmbedding

  return {
    id,
    name,
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

  models.forEach((model, index) => {
    lines.push(`        "${model.id}": {`)
    lines.push(`          "name": ${JSON.stringify(model.name)},`)

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

  if (models.length > 0) {
    lines.push("        // Intentionally omitted:")
    lines.push('        // "text-embedding-005"')
    lines.push("        //")
    lines.push("        // That model appears to be an embedding model, not a chat/coding model.")
    lines.push("        // Add it only if OpenCode/USAI exposes a separate embedding-model config path.")
  }

  if (models.length > 0) {
    const lastModelLine = lines.findLastIndex((line) => line === "        },")
    lines[lastModelLine] = "        }"
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

export function updateTemplate(templateText, payload) {
  const eol = templateText.includes("\r\n") ? "\r\n" : "\n"
  const rawModels = Array.isArray(payload)
    ? payload
    : Array.isArray(payload.data)
      ? payload.data
      : Array.isArray(payload.models)
        ? payload.models
        : []

  const models = rawModels
    .map(parseModel)
    .filter((model) => model.id)
    .filter(isAllowedModel)
    .sort((a, b) => a.id.localeCompare(b.id))

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
  const useFixture = args.includes("--fixture") || fixtureArg || !process.env.USAI_API_KEY

  if (useFixture) {
    return JSON.parse(await readFile(fixturePath, "utf8"))
  }

  const response = await fetch("https://api.gsa.usai.gov/api/v1/models", {
    headers: {
      accept: "application/json",
      authorization: `Bearer ${process.env.USAI_API_KEY}`,
    },
  })

  if (!response.ok) {
    throw new Error(`USAI models request failed: ${response.status}`)
  }

  return response.json()
}

async function main() {
  const args = process.argv.slice(2)
  const checkOnly = args.includes("--check")
  const writeSnapshot = args.includes("--write-snapshot")
  const templatePathArg = args.find((arg) => arg.startsWith("--template="))
  const templatePath = templatePathArg ? path.resolve(templatePathArg.split("=")[1]) : DEFAULT_TEMPLATE_PATH

  const [templateText, payload] = await Promise.all([
    readFile(templatePath, "utf8"),
    loadPayload(args),
  ])

  const { updatedTemplate, models } = updateTemplate(templateText, payload)

  if (checkOnly) {
    if (templateText !== updatedTemplate) {
      throw new Error("Template is out of date with the current model payload")
    }
    return
  }

  await writeFile(templatePath, updatedTemplate)

  if (writeSnapshot) {
    const snapshotPath = path.resolve("tests/output/latest-opencode.jsonc")
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
