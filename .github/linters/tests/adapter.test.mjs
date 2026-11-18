import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { applyFixes, getVersion } from "markdownlint";
import { lint } from "markdownlint/sync";
import { markdownFiles } from "../markdown-files.mjs";
import { lintFiles, markdownItFactory } from "../run-markdownlint.mjs";

const wrapper = fileURLToPath(new URL("../run-markdownlint.mjs", import.meta.url));
const repositoryConfig = fs.readFileSync(new URL("../../../.markdownlint.jsonc", import.meta.url), "utf8");
const repositoryIgnore = fs.readFileSync(new URL("../../../.markdownlintignore", import.meta.url), "utf8");
const config = JSON.stringify({ default: false, MD009: true, MD010: true, MD012: true, MD047: true });

function fixture(t, contents = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "markdown-adapter-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  put(root, ".markdownlint.jsonc", config);
  put(root, ".markdownlintignore", repositoryIgnore);
  for (const [name, text] of Object.entries(contents)) put(root, name, text);
  return root;
}

function put(root, name, text) {
  const target = path.join(root, name);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, text);
}

function run(root, ...args) {
  const result = spawnSync(process.execPath, [wrapper, ...args], {
    cwd: root, encoding: "utf8", timeout: 15000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}

test("pinned engine and the adapter's markdown-it factory really parse HTML", () => {
  assert.equal(getVersion(), "0.41.1");
  let observed = false;
  const result = lint({
    strings: { sample: "<div>\nraw\n</div>\n" },
    config: { default: false, TESTHTML: true },
    markdownItFactory,
    customRules: [{
      names: ["TESTHTML"], tags: ["test"], description: "HTML parser contract",
      parser: "markdownit",
      function(params) {
        observed = true;
        assert.ok(params.parsers.markdownit.tokens.some((token) => token.type === "html_block"));
      },
    }],
  });
  assert.ok(observed);
  assert.deepEqual(result.sample, []);
});

test("Quickstart selection includes hidden files, aliases, Unicode, templates and fixtures", (t) => {
  const root = fixture(t, {
    "a.md": "ok\n", ".hidden/é space.md": "ok\n", ".root.md": "ok\n",
    "node_modules/no.md": "bad", ".github/linters/node_modules/no.md": "bad",
    "deleteme/no.md": "bad", "tmp/no.md": "bad", "CHANGELOG.md": "bad",
    "test/vendor/no.md": "bad", "templates/yes.md": "ok\n",
    "fixtures/yes.md": "ok\n", "deep/fixtures/yes.md": "ok\n",
    "deep/Fixtures/yes.md": "ok\n", "deep/templates/yes.md": "ok\n",
    "deep/node_modules/no.md": "bad", "deep/deleteme/no.md": "bad",
    "deep/CHANGELOG.md": "bad", ".agents/skills/one.md": "ok\n",
    "deep/test/vendor/yes.md": "ok\n", ".github/pull_request_template.md": "ok\n",
    "not.markdown": "bad", "not.mdx": "bad",
  });
  fs.symlinkSync(".agents/skills", path.join(root, "skills"), "dir");
  fs.symlinkSync("a.md", path.join(root, "alias.md"), "file");
  const expected = [
    ".agents/skills/one.md", ".github/pull_request_template.md", ".hidden/é space.md",
    ".root.md", "a.md", "alias.md", "deep/Fixtures/yes.md", "deep/fixtures/yes.md",
    "deep/templates/yes.md", "deep/test/vendor/yes.md", "fixtures/yes.md",
    "skills/one.md", "templates/yes.md",
  ].sort();
  assert.deepEqual(markdownFiles(root), expected);
  assert.deepEqual(markdownFiles(root), expected);
  assert.equal(run(root, "--count-only").stdout, `${expected.length}\n`);
  assert.equal(run(root).status, 0);
});

test("extension follows CLI platform policy without Patterns fixture exclusions", (t) => {
  const root = fixture(t, { "upper.MD": "ok\n", "lower.md": "ok\n", "Fixtures/yes.md": "ok\n" });
  assert.deepEqual(markdownFiles(root, "linux"), ["Fixtures/yes.md", "lower.md"]);
  for (const platform of ["darwin", "win32"]) {
    assert.deepEqual(markdownFiles(root, platform), ["Fixtures/yes.md", "lower.md", "upper.MD"]);
  }
});

test("ignore patterns preserve negation, case, comments, escapes and directory pruning", (t) => {
  const root = fixture(t, {
    "a.md": "ok\n", "space name.md": "bad", "deep/skip.md": "bad",
    "deep/keep.md": "ok\n", "UPPER.md": "bad", "#literal.md": "bad",
    "excluded/keep.md": "bad", "root-only.md": "bad", "nested/root-only.md": "ok\n",
    ".markdownlintignore": "# comment\nspace name.md\ndeep/*.md\n!deep/keep.md\nupper.md\n\\#literal.md\nexcluded/\n!excluded/keep.md\n/root-only.md\n",
  });
  assert.deepEqual(markdownFiles(root), ["a.md", "deep/keep.md", "nested/root-only.md"]);
  assert.equal(run(root, "--count-only").stdout, "3\n");
  assert.equal(run(root).status, 0);
});

test("no Patterns hard exclusions; changing ignore file governs root names and aliases", (t) => {
  const root = fixture(t, { "source/a.md": "ok\n", "CHANGELOG.md": "ok\n", ".markdownlintignore": "" });
  fs.symlinkSync("source", path.join(root, "templates"), "dir");
  assert.deepEqual(markdownFiles(root), ["CHANGELOG.md", "source/a.md", "templates/a.md"]);
});

test("ignored dependencies, vendor paths and Git metadata are not traversed", (t) => {
  const root = fixture(t, { "a.md": "ok\n" });
  for (const name of ["node_modules", ".github/linters/node_modules", "test/vendor", ".git"]) {
    put(root, `${name}/bad.md`, "bad");
    fs.symlinkSync("missing", path.join(root, name, "broken"), "dir");
    fs.symlinkSync(os.tmpdir(), path.join(root, name, "outside"), "dir");
  }
  assert.deepEqual(markdownFiles(root), ["a.md"]);
  assert.equal(run(root).status, 0);
});

test("directory-only ignores prune symlink aliases without hiding regular files", (t) => {
  const root = fixture(t, {
    "source/a.md": "ok\n", "literal.md": "ok\n",
    ".markdownlintignore": "alias/\nliteral.md/\n",
  });
  fs.symlinkSync(os.tmpdir(), path.join(root, "alias"), "dir");
  assert.deepEqual(markdownFiles(root), ["literal.md", "source/a.md"]);
});

test("cycles, escaping links and broken links fail explicitly instead of dropping files", (t) => {
  for (const kind of ["cycle", "escape", "broken"]) {
    const root = fixture(t, { "a.md": "ok\n", "sub/b.md": "ok\n" });
    const target = kind === "cycle" ? ".." : kind === "escape" ? os.tmpdir() : "missing";
    fs.symlinkSync(target, path.join(root, "sub/link"), "dir");
    const result = run(root, "--count-only");
    assert.equal(result.status, 4, kind);
    assert.equal(result.stdout, "", kind);
    assert.match(result.stderr, /cycle|escapes repository|ENOENT/, kind);
  }
});

test("zero selected files fails for check, fix and count, including all-ignored input", (t) => {
  for (const contents of [{}, { "a.md": "ok\n", ".markdownlintignore": "*.md\n" }, { "CHANGELOG.md": "ok\n" }]) {
    const root = fixture(t, contents);
    for (const args of [[], ["--fix"], ["--count-only"]]) {
      const result = run(root, ...args);
      assert.equal(result.status, 4);
      assert.equal(result.stdout, "");
      assert.match(result.stderr, /matched no files/);
    }
  }
});

test("only supported wrapper flags are accepted, without changing files", (t) => {
  const root = fixture(t, { "a.md": "bad" });
  for (const flag of ["--json", "--config", "a.md", "--check", "--", "--fix=true"]) {
    assert.equal(run(root, "--fix", flag).status, 4);
    assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "bad");
  }
  assert.equal(run(root, "--fix", "--count-only").stdout, "1\n");
  assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "bad");
});

test("diagnostics preserve error/warning severity, location, detail, context and sorting", (t) => {
  const root = fixture(t, { "z.md": "bad", "a.md": "bad" });
  const expected = ["a.md", "z.md"].map((name) =>
    `${name}:1:3 error MD047/single-trailing-newline Files should end with a single newline character\n`
  ).join("");
  const result = run(root);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, "");
  assert.equal(result.stderr, expected);
  put(root, ".markdownlint.jsonc", '{"default":false,"MD047":"warning"}');
  const warning = run(root);
  assert.equal(warning.status, 0);
  assert.equal(warning.stderr, expected.replaceAll(" error ", " warning "));
  put(root, ".markdownlint.jsonc", '{"default":false,"MD013":{"line_length":3},"MD001":true,"MD018":true}');
  put(root, "a.md", "# A\n\n### Heading\n\n#Missing\n");
  const detailed = run(root);
  assert.equal(detailed.status, 1);
  assert.match(detailed.stderr, /MD001\/heading-increment .*\[Expected: h2; Actual: h3\]/);
  assert.match(detailed.stderr, /MD018\/no-missing-space-atx .*\[Context: "#Missing"\]/);
  assert.match(detailed.stderr, /MD013\/line-length .*\[Expected: 3; Actual: 11\]/);
});

test("fix handles missing and extra EOF newlines, CRLF and overlapping fixes", (t) => {
  for (const [input, expected] of [
    ["text", "text\n"], ["text\n\n\n", "text\n"],
    ["# T\r\n\r\ntext   \r\n", "# T\r\n\r\ntext\r\n"], ["text   ", "text\n"],
  ]) {
    const root = fixture(t, { "a.md": input });
    assert.equal(run(root).status, 1);
    assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), input);
    const fixed = run(root, "--fix");
    assert.equal(fixed.status, 0, fixed.stderr);
    assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), expected);
    assert.equal(run(root, "--fix").status, 0);
    assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), expected);
  }
});

test("BOM fix output preserves the engine's single-pass behavior", (t) => {
  const input = "\uFEFFtext";
  const root = fixture(t, { "a.md": input });
  const errors = lint({ strings: { sample: input }, config: { default: false, MD047: true } }).sample;
  run(root, "--fix");
  assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), applyFixes(input, errors));
});

test("fix relints and leaves an unfixable violation failing", (t) => {
  const root = fixture(t, { "a.md": "too long" });
  put(root, ".markdownlint.jsonc", '{"default":false,"MD047":true,"MD013":{"line_length":3}}');
  const result = run(root, "--fix");
  assert.equal(result.status, 1);
  assert.match(result.stderr, /MD013/);
  assert.doesNotMatch(result.stderr, /MD047/);
  assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "too long\n");
});

test("repository rule configuration, default frontmatter and inline directives are retained", (t) => {
  const root = fixture(t, {
    "a.md": "---\ntitle: Example\n---\n\n<div>HTML allowed</div>\n\n<!-- markdownlint-disable MD047 -->\ntext",
  });
  put(root, ".markdownlint.jsonc", repositoryConfig);
  assert.equal(run(root).status, 0);
  put(root, "a.md", "---\ntitle: Example\n---\n\ntext");
  const result = run(root);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /^a\.md:5:4 error MD047/m);
});

test("config.frontMatter remains inert even when it would match the whole file", (t) => {
  const root = fixture(t, { "a.md": "text" });
  put(root, ".markdownlint.jsonc", JSON.stringify({ default: false, MD047: true, frontMatter: "^[\\s\\S]*$" }));
  assert.match(run(root).stderr, /MD047/);
});

test("JSONC comments and trailing commas survive in required and extended config", (t) => {
  const root = fixture(t, { "a.md": "text" });
  put(root, "parent.jsonc", '{/* parent */ "default": false, "MD047": true,}\n');
  put(root, ".markdownlint.jsonc", '{// child\n "extends": "parent.jsonc",}\n');
  assert.equal(run(root).status, 1);
  assert.equal(run(root, "--fix").status, 0);
  assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "text\n");
});

test("missing and unreadable required or extended config fail before fixes", (t) => {
  const root = fixture(t, { "a.md": "text" });
  put(root, ".markdownlint.jsonc", '{"extends":"missing.jsonc"}');
  assert.equal(run(root, "--fix").status, 4);
  fs.unlinkSync(path.join(root, ".markdownlint.jsonc"));
  assert.equal(run(root, "--fix").status, 4);
  fs.mkdirSync(path.join(root, ".markdownlint.jsonc"));
  assert.equal(run(root, "--fix").status, 4);
  assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "text");
});

test("required and extended JSONC reject malformed or non-object configs before fixes", (t) => {
  const root = fixture(t, { "a.md": "text" });
  for (const text of ["null", "true", "42", '"scalar"', "[]", "", "// only a comment\n",
    '{"MD047":', '{"MD047":true garbage}', '{MD047:true}', "default: false\n", '{"MD047":true} {}']) {
    for (const extended of [false, true]) {
      put(root, ".markdownlint.jsonc", extended ? '{"extends":"parent.jsonc"}' : text);
      put(root, "parent.jsonc", text);
      for (const args of [[], ["--fix"]]) {
        const result = run(root, ...args);
        assert.equal(result.status, 4, `${JSON.stringify({ text, extended, args })}: ${result.stderr}`);
        assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "text");
      }
    }
  }
  put(root, ".markdownlint.jsonc", "{}\n");
  assert.equal(run(root).status, 1, "an explicit empty object uses engine defaults");
});

test("ambient rc and alternate config files cannot override required JSONC", (t) => {
  const root = fixture(t, { "a.md": "text" });
  put(root, ".markdownlintrc", '{"default":false}');
  put(root, ".markdownlint.json", '{"default":false}');
  put(root, ".markdownlint.yaml", "default: false\n");
  assert.equal(run(root).status, 1);
});

test("a file deleted after selection is an engine read failure, not silently skipped", (t) => {
  const root = fixture(t, { "a.md": "text\n" });
  const files = markdownFiles(root);
  fs.unlinkSync(path.join(root, "a.md"));
  const previous = process.cwd();
  try {
    process.chdir(root);
    assert.throws(() => lintFiles(files), /ENOENT/);
    assert.throws(() => lintFiles(files, { fix: true }), /ENOENT/);
  } finally {
    process.chdir(previous);
  }
});

test("required ignore file cannot be missing or unreadable", (t) => {
  const root = fixture(t, { "a.md": "text" });
  fs.unlinkSync(path.join(root, ".markdownlintignore"));
  for (const args of [[], ["--fix"], ["--count-only"]]) assert.equal(run(root, ...args).status, 4);
  fs.mkdirSync(path.join(root, ".markdownlintignore"));
  assert.equal(run(root, "--count-only").status, 4);
  assert.equal(fs.readFileSync(path.join(root, "a.md"), "utf8"), "text");
});

test("read, traversal and fix-write failures remain nonzero", { skip: process.platform === "win32" || process.getuid?.() === 0 }, (t) => {
  const root = fixture(t, { "a.md": "text", "private/b.md": "ok\n" });
  const file = path.join(root, "a.md");
  const directory = path.join(root, "private");
  try {
    fs.chmodSync(file, 0);
    assert.equal(run(root).status, 4);
    fs.chmodSync(file, 0o400);
    assert.equal(run(root, "--fix").status, 4);
    fs.chmodSync(file, 0o600);
    fs.chmodSync(directory, 0);
    assert.equal(run(root, "--count-only").status, 4);
  } finally {
    fs.chmodSync(file, 0o600);
    fs.chmodSync(directory, 0o700);
  }
  assert.equal(fs.readFileSync(file, "utf8"), "text");
});
