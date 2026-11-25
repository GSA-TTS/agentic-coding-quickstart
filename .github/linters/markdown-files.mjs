// Fixed Quickstart selection, not a glob implementation. See ADR-0046.
import fs from "node:fs";
import path from "node:path";
import ignore from "ignore";

export function markdownFiles(cwd = process.cwd(), platform = process.platform) {
  const root = path.resolve(cwd);
  const realRoot = fs.realpathSync(root);
  const foldExtension = platform === "darwin" || platform === "win32";
  const ignored = ignore().add(fs.readFileSync(path.join(root, ".markdownlintignore"), "utf8"));
  const files = [];
  walk(root, "", new Set());
  return files.sort();

  function contained(target, relative) {
    const outside = path.relative(realRoot, target);
    if (outside === ".." || outside.startsWith(`..${path.sep}`) || path.isAbsolute(outside)) {
      throw new Error(`Markdown traversal escapes repository: ${relative}`);
    }
  }

  function walk(directory, prefix, ancestors) {
    const real = fs.realpathSync(directory);
    contained(real, prefix);
    if (ancestors.has(real)) throw new Error(`Markdown symlink cycle: ${prefix}`);
    // Branch-local ancestry retains distinct lexical aliases to one target.
    const branch = new Set([...ancestors, real]);
    const entries = fs.readdirSync(directory, { withFileTypes: true });
    entries.sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
    for (const entry of entries) {
      const relative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const absolute = path.join(directory, entry.name);
      // Ignore Git metadata even in worktrees. Prune ignore-file exclusions
      // before resolving links or entering dependency/vendor directories.
      if (entry.name === ".git" || ignored.ignores(relative)) continue;
      if (entry.isDirectory() && ignored.ignores(`${relative}/`)) continue;
      let info = entry;
      if (entry.isSymbolicLink()) {
        info = fs.statSync(absolute);
        if (info.isDirectory() && ignored.ignores(`${relative}/`)) continue;
        const target = fs.realpathSync(absolute);
        contained(target, relative);
      }
      if (info.isDirectory()) {
        if (!ignored.ignores(`${relative}/`)) walk(absolute, relative, branch);
      } else {
        const name = foldExtension ? entry.name.toLowerCase() : entry.name;
        if (name.endsWith(".md")) {
          if (!info.isFile()) throw new Error(`Not a regular Markdown file: ${relative}`);
          files.push(relative);
        }
      }
    }
  }
}
