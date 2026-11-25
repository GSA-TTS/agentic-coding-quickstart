#!/usr/bin/env node
// Repository adapter, not a general markdownlint-cli replacement.
// Usage: node .github/linters/run-markdownlint.mjs [--fix] [--count-only]
// Run from the repository root. See docs/adr/0046-markdown-engine-adapter.md.
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { applyFixes } from "markdownlint";
import { lint, readConfig } from "markdownlint/sync";
import markdownIt from "markdown-it";
import { parse, printParseErrorCode } from "jsonc-parser";
import { markdownFiles } from "./markdown-files.mjs";

const configParsers = [(text) => {
  const errors = [];
  const config = parse(text, errors, { allowTrailingComma: true });
  if (errors.length) {
    throw new Error(`Unable to parse JSON(C) content, ${errors.map((error) =>
      printParseErrorCode(error.error)).join(", ")}`);
  }
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    throw new Error("Markdown configuration must be a JSON object");
  }
  return config;
}];

export const markdownItFactory = () => markdownIt({ html: true });

// Preserve the CLI's text format and ordering, including warning-only success.
export function diagnostics(results) {
  const entries = Object.entries(results).flatMap(([file, errors]) =>
    errors.map((error) => ({
      file,
      line: error.lineNumber,
      column: error.errorRange?.[0] || 0,
      names: error.ruleNames.join("/"),
      severity: error.severity,
      description: error.ruleDescription +
        (error.errorDetail ? ` [${error.errorDetail}]` : "") +
        (error.errorContext ? ` [Context: "${error.errorContext}"]` : ""),
    }))
  );
  entries.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line ||
    a.names.localeCompare(b.names) || a.description.localeCompare(b.description));
  return {
    text: entries.map(({ file, line, column, severity, names, description }) =>
      `${file}:${line}${column ? `:${column}` : ""} ${severity} ${names} ${description}`
    ).join("\n"),
    status: entries.some(({ severity }) => severity === "error") ? 1 : 0,
  };
}

// Read Quickstart's JSONC explicitly; readConfig retains engine extends
// semantics. Do not promote the historical config.frontMatter string into a
// top-level engine option: the old CLI passed it only inside config, too.
export function lintFiles(files, { fix = false } = {}) {
  const options = {
    files,
    config: readConfig(".markdownlint.jsonc", configParsers),
    configParsers,
    markdownItFactory,
  };
  if (fix) {
    // Exactly one fix pass per file, then lint the complete selection again.
    // Use files (not strings) so inline config and file-read failures survive.
    for (const file of files) {
      const fixes = lint({ ...options, files: [file] })[file]
        .filter((error) => error.fixInfo);
      if (fixes.length) {
        const original = readFileSync(file, "utf8");
        const fixed = applyFixes(original, fixes);
        if (fixed !== original) writeFileSync(file, fixed, "utf8");
      }
    }
  }
  return lint(options);
}

export function run(args = process.argv.slice(2)) {
  try {
    const unsupported = args.find((arg) => !["--fix", "--count-only"].includes(arg));
    if (unsupported !== undefined) throw new Error(`Unsupported argument: ${unsupported}`);
    const files = markdownFiles();
    if (!files.length) throw new Error("markdownlint matched no files");
    if (args.includes("--count-only")) {
      // Plain stdout, not console.log: with FORCE_COLOR (pre-commit --color=always)
      // console.log colors a bare number, which breaks callers that compare the count.
      process.stdout.write(`${files.length}\n`);
      return 0;
    }
    const result = diagnostics(lintFiles(files, { fix: args.includes("--fix") }));
    if (result.text) console.error(result.text);
    return result.status;
  } catch (error) {
    console.error(error);
    return 4;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = run();
}
