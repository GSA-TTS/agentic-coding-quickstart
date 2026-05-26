// Commitlint Configuration
// See: https://commitlint.js.org/

// Extend conventional commit configuration
export default {
  extends: ['@commitlint/config-conventional'],

  // Ignore Dependabot commits (they follow conventional commits but may have extra metadata)
  ignores: [
    (message) => /^chore\(deps\)|^chore\(ci\)/.test(message)
  ],

  // Custom rules
  rules: {
    // Type must be one of these
    'type-enum': [
      2,  // Level: error
      'always',
      [
        'feat',      // New feature (minor version bump)
        'fix',       // Bug fix (patch version bump)
        'docs',      // Documentation only (no version bump)
        'style',     // Code style/formatting (no version bump)
        'refactor',  // Code refactoring (no version bump)
        'perf',      // Performance improvement (patch version bump)
        'test',      // Test changes (no version bump)
        'chore',     // Maintenance tasks (no version bump)
        'ci',        // CI/CD changes (no version bump)
        'build',     // Build system changes (no version bump)
        'revert',    // Revert previous commit
        'security'   // Security fixes (patch version bump)
      ]
    ],

    // Subject must not be empty
    'subject-empty': [2, 'never'],

    // Subject must not end with period
    'subject-full-stop': [2, 'never', '.'],

    // Subject must be lowercase
    'subject-case': [2, 'always', 'lower-case'],

    // Type must be lowercase
    'type-case': [2, 'always', 'lower-case'],

    // Scope must be lowercase
    'scope-case': [2, 'always', 'lower-case'],

    // Header maximum length
    'header-max-length': [2, 'always', 100],

    // Body maximum line length
    'body-max-line-length': [2, 'always', 100],

    // Footer maximum line length
    'footer-max-line-length': [2, 'always', 100]
  }
};
