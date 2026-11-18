// Optional migration oracle. Supply an independently installed, reviewed
// markdownlint-cli 0.49.1 baseline with Quickstart's original lockfile in the
// sandbox. It is deliberately NOT a production dependency of the adapter.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { test } from "node:test";
import { markdownFiles } from "../markdown-files.mjs";

const baseline = process.env.MARKDOWNLINT_BASELINE_CLI;
const wrapper = fileURLToPath(new URL("../run-markdownlint.mjs", import.meta.url));
const rule = fileURLToPath(new URL("./fixtures/selection-rule.cjs", import.meta.url));
const repository = fileURLToPath(new URL("../../..", import.meta.url));
const repositoryIgnore = fs.readFileSync(path.join(repository, ".markdownlintignore"), "utf8");
const oldArgs = ["--config", ".markdownlint.jsonc", "--ignore-path", ".markdownlintignore", "--dot", "**/*.md"];

function invoke(script, args, cwd, env = process.env) {
  const result = spawnSync(process.execPath, [script, ...args], { cwd, env, encoding: "utf8", timeout: 60000 });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}

function selection(root, log) {
  const result = invoke(baseline, [...oldArgs, "--rules", rule, "--enable", "TESTSELECT", "--"], root,
    { ...process.env, MARKDOWN_SELECTION_LOG: log });
  assert.ok([0, 1].includes(result.status), result.stderr);
  const selected = fs.readFileSync(log, "utf8").trim().split("\n").map(JSON.parse).sort();
  assert.deepEqual(markdownFiles(root), selected);
  assert.equal(invoke(wrapper, ["--count-only"], root).stdout, `${selected.length}\n`);
  return selected;
}

function temporary(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "markdown-parity-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

function put(root, name, text) {
  fs.mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
  fs.writeFileSync(path.join(root, name), text);
}

function compare(oldRoot, newRoot, fix = false) {
  const old = invoke(baseline, [...oldArgs, ...(fix ? ["--fix"] : [])], oldRoot);
  const current = invoke(wrapper, fix ? ["--fix"] : [], newRoot);
  assert.ok([0, 1].includes(old.status), old.stderr);
  assert.equal(current.status, old.status);
  assert.equal(current.stderr, old.stderr);
  assert.equal(current.stdout, old.stdout);
}

test("complete baseline selection and diagnostics on the real repository", { skip: !baseline }, (t) => {
  const temp = temporary(t);
  const manifest = JSON.parse(fs.readFileSync(path.join(path.dirname(baseline), "package.json"), "utf8"));
  assert.equal(manifest.name, "markdownlint-cli");
  assert.equal(manifest.version, "0.49.1");
  const selected = selection(repository, path.join(temp, "selection.jsonl"));
  assert.ok(selected.includes("README.md"));
  assert.ok(selected.some((name) => name.startsWith(".github/")));
  compare(repository, repository);
});

test("full repository Markdown fixed bytes agree in disposable copies", { skip: !baseline }, (t) => {
  const temp = temporary(t);
  const selected = selection(repository, path.join(temp, "selection.jsonl"));
  const oldRoot = path.join(temp, "old");
  const newRoot = path.join(temp, "new");
  // Copy every selected lexical input, including clean files; never fix the
  // working repository. Current Quickstart config has no external extends.
  const names = [...selected, ".markdownlint.jsonc", ".markdownlintignore"];
  for (const root of [oldRoot, newRoot]) {
    for (const name of names) put(root, name, fs.readFileSync(path.join(repository, name)));
  }
  selection(oldRoot, path.join(temp, "old-selection.jsonl"));
  selection(newRoot, path.join(temp, "new-selection.jsonl"));
  assert.deepEqual(markdownFiles(newRoot), selected);
  compare(oldRoot, newRoot, true);
  for (const name of names) {
    assert.deepEqual(fs.readFileSync(path.join(newRoot, name)), fs.readFileSync(path.join(oldRoot, name)), name);
  }
});

test("synthetic baseline selection, diagnostics and one-pass fix bytes", { skip: !baseline }, (t) => {
  const temp = temporary(t);
  const oldRoot = path.join(temp, "old");
  const newRoot = path.join(temp, "new");
  const contents = {
    ".markdownlint.jsonc": '{// JSONC child\n"extends":"parent.jsonc"}\n',
    "parent.jsonc": '{/* JSONC parent */ "default":false,"MD001":true,"MD009":true,"MD012":true,"MD018":true,"MD047":true,"MD013":{"line_length":20,"severity":"warning",},}\n',
    ".markdownlintignore": repositoryIgnore + "ignored.md\n*.skip.md\n!keep.skip.md\n",
    "a.md": "# A\n\n### Skipped level\n\n#Missing\n\ntext   ",
    "bom.md": "\uFEFFtext", "crlf.md": "# H\r\n\r\ntext   \r\n",
    "eof.md": "text\n\n\n", "warning.md": "a very long line exceeding twenty columns\n",
    ".hidden/space é.md": "text", ".agents/skills/a.md": "clean\n",
    "frontmatter.md": "---\ntitle: Example\n---\n\ntext",
    "inline.md": "<!-- markdownlint-disable MD047 -->\ntext",
    "html.md": "<div>\nraw\n</div>\n", "upper.MD": "text", "CHANGELOG.md": "excluded",
    "templates/yes.md": "text", "node_modules/no.md": "excluded",
    ".github/linters/node_modules/no.md": "excluded", "deleteme/no.md": "excluded",
    "tmp/no.md": "excluded", "test/vendor/no.md": "excluded",
    "deep/test/vendor/yes.md": "text", "deep/fixtures/yes.md": "text", "deep/Fixtures/yes.md": "text",
    "deep/templates/yes.md": "text", "deep/node_modules/no.md": "excluded",
    "deep/CHANGELOG.md": "excluded", "deep/deleteme/no.md": "excluded",
    "ignored.md": "excluded", "other.skip.md": "excluded", "keep.skip.md": "text",
  };
  for (const root of [oldRoot, newRoot]) {
    for (const [name, text] of Object.entries(contents)) put(root, name, text);
    fs.symlinkSync(".agents/skills", path.join(root, "skills"), "dir");
    fs.symlinkSync("a.md", path.join(root, "alias.md"), "file");
  }
  selection(newRoot, path.join(temp, "selection.jsonl"));
  for (const fix of [false, true]) {
    compare(oldRoot, newRoot, fix);
    for (const name of Object.keys(contents)) {
      assert.deepEqual(fs.readFileSync(path.join(newRoot, name)), fs.readFileSync(path.join(oldRoot, name)), name);
    }
  }
});

test("baseline JSONC comments, trailing commas and inert frontMatter are discriminating", { skip: !baseline }, (t) => {
  const temp = temporary(t);
  const oldRoot = path.join(temp, "old");
  const newRoot = path.join(temp, "new");
  for (const root of [oldRoot, newRoot]) {
    put(root, ".markdownlintignore", "");
    put(root, "a.md", "text");
    put(root, ".markdownlint.jsonc", '{/* comment */ "extends":"parent.jsonc"}\n');
    put(root, "parent.jsonc", '{"default":false,"MD047":true,"frontMatter":"^[\\\\s\\\\S]*$",}\n');
  }
  compare(oldRoot, newRoot);
  const old = invoke(baseline, oldArgs, oldRoot);
  assert.equal(old.status, 1);
  assert.match(old.stderr, /MD047/);
  compare(oldRoot, newRoot, true);
  assert.equal(fs.readFileSync(path.join(newRoot, "a.md"), "utf8"), "text\n");
  assert.deepEqual(fs.readFileSync(path.join(newRoot, "a.md")), fs.readFileSync(path.join(oldRoot, "a.md")));
});

test("root JSONC trailing comma intentionally bypasses the old ambient loader limitation", { skip: !baseline }, (t) => {
  const root = temporary(t);
  put(root, ".markdownlintignore", "");
  put(root, "a.md", "text");
  put(root, ".markdownlint.jsonc", '{"default":false,"MD047":true,}\n');
  const old = invoke(baseline, oldArgs, root);
  assert.equal(old.status, 4);
  assert.match(old.stderr, /SyntaxError/);
  const current = invoke(wrapper, [], root);
  assert.equal(current.status, 1);
  assert.match(current.stderr, /MD047/);
  assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "text");
});
