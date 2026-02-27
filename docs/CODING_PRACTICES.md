# Secure Coding Practices for AI-Assisted Federal Development

> **Source:** Adapted from [cloud-gov/federal-agentic-ai-guidance](https://github.com/cloud-gov/federal-agentic-ai-guidance)
> **Version:** 0.1.0 | **Impact Level:** FIPS Moderate | **Scope:** Single-agent, internal enterprise

## Quick Reference

| Domain | Key Rules |
|--------|-----------|
| Input | Validate ALL external input server-side, parameterized queries only, allowlist over denylist |
| Output | Context-appropriate encoding, no internal details in error messages |
| Secrets | Never in source code, use approved KMS (Vault, AWS SM, Azure KV, SOPS), rotate regularly |
| Auth | Authenticate all endpoints, server-side authorization, framework-native session management |
| Dependencies | Pin exact versions, commit lock files, no critical/high CVEs, verify package names |
| Errors | Explicit handling, structured logging, no sensitive data in logs |
| Crypto | FIPS-validated algorithms only, no custom implementations, TLS 1.2+ |
| Architecture | ADRs for design decisions, Design by Contract, interfaces before implementations |
| Change Safety | TDD (red-green-refactor), regression tests for bug fixes, idempotent operations |
| Size Limits | Functions ≤50 lines, files ≤400 lines, cyclomatic complexity ≤10, params ≤5 |

---

## 1. AI-Generated Code: Additional Responsibilities

AI-generated code requires **the same security scrutiny** as human-written code — plus additional verification steps.

### 1.1 Code Provenance

- All AI-generated code MUST be attributed (e.g., `Co-Authored-By` in commits)
- Developers MUST review all AI-generated code before committing
- AI-generated code MUST NOT be deployed to production without human review

### 1.2 Known Limitations

AI-generated code may:
- Contain plausible-looking but incorrect logic
- Reference APIs or libraries that do not exist
- Reproduce insecure patterns from training data
- Lack awareness of agency-specific requirements

**Mitigation:** Verify against official documentation, test edge cases, run security scanners.

---

## 2. Input Validation and Output Encoding

### 2.1 Input Validation Rules

All external input MUST be validated before use:

| Input Type | Validation Required |
|---|---|
| String input | Max length, character allowlist, encoding |
| Numeric input | Range check, type coercion safety |
| File uploads | Extension allowlist, MIME type, size limit |
| URLs | Protocol allowlist (https only), domain allowlist |
| File paths | Path traversal prevention |
| Shell commands | Avoid; use library APIs not shell strings |

### 2.2 Output Encoding

| Context | Encoding |
|---|---|
| HTML body | HTML entity encoding |
| JavaScript | JavaScript string escaping |
| URLs | URL/percent encoding |
| Shell | Avoid; use APIs. If unavoidable, shell-escape all arguments |
| JSON | Proper serialization — never string concatenation |
| Log files | Sanitize newlines and control characters |

---

## 3. Secrets Management

### 3.1 Rules

- MUST NOT hardcode secrets in source code
- MUST NOT commit secrets to version control
- MUST use approved secrets management (SOPS/AGE for this project)
- MUST rotate secrets on a defined schedule
- MUST revoke compromised secrets immediately

### 3.2 Prevention

- Configure pre-commit hooks to scan for secrets (gitleaks, detect-secrets)
- Include secret patterns in .gitignore:
  ```
  .env
  .env.*
  *.key
  *.pem
  credentials.*
  ```

---

## 4. Dependency and Supply Chain Security

### 4.1 Dependency Selection

Before adding any dependency, verify:

| Check | Requirement |
|---|---|
| Maintenance | Active commits within last 6 months |
| Vulnerabilities | No unpatched critical/high CVEs |
| License | Compatible with federal use |
| Package name | Verify spelling — check for typosquatting |

### 4.2 Dependency Management

- MUST pin exact versions in production
- MUST commit lock files
- MUST run vulnerability scanning in CI/CD
- SHOULD generate SBOM in SPDX or CycloneDX format

---

## 5. Error Handling and Logging

### 5.1 Error Handling

- MUST handle all errors explicitly — no empty catch blocks
- MUST NOT expose internal details in error messages
- MUST use structured error types with error codes
- MUST log errors with sufficient context

### 5.2 Logging

**What to log:**
- Authentication events (success and failure)
- Authorization decisions
- Data access events
- Administrative actions
- Error conditions

**What MUST NOT be logged:**
- Passwords, tokens, or secrets
- Full credit card or SSN
- PII unless required and approved

---

## 6. Architecture Discipline

### 6.1 Architecture Decision Records (ADRs)

- MUST write an ADR before making architectural changes
- MUST include rejected alternatives with trade-offs
- MUST require peer review of ADRs
- Store in `docs/decisions/` using `NNNN-title.md` format

### 6.2 Design by Contract

- Define interface contracts before implementations
- Validate preconditions at system boundaries
- Document contracts using types, assertions, or schema validation

### 6.3 Separation of Concerns

- Enforce one-way dependency flow
- Don't mix infrastructure (database, HTTP) with business logic
- Isolate side effects behind testable interfaces

---

## 7. Change Safety and Verification

### 7.1 Test-Driven Development

- MUST write failing test before production code (red → green → refactor)
- MUST NOT merge code without corresponding tests
- MUST run full test suite before committing

### 7.2 Regression Tests

- MUST add regression test for every resolved defect
- Test MUST fail against broken state, pass against fix
- Label regression tests for traceability

### 7.3 Idempotent Operations

- Design state-changing operations to be idempotent
- Produce deterministic output given same inputs
- Use seed values in tests for reproducibility

---

## 8. Scope, Simplicity, and Maintainability

### 8.1 KISS and YAGNI

- MUST NOT implement speculative features
- Prefer simplest solution that satisfies requirements
- Don't add configurability unless current task requires it

### 8.2 DRY and Rule of Three

- Extract shared logic only at three+ occurrences
- Don't DRY prematurely
- Prefer composition over inheritance

### 8.3 Size and Complexity Limits

| Metric | Limit |
|--------|-------|
| Functions | ≤50 lines of logic |
| Files/modules | ≤400 lines |
| Cyclomatic complexity | ≤10 per function |
| Function parameters | ≤5 |

Exceptions require written justification in PR description.

### 8.4 SOLID Principles

- **SRP:** Each function/module has one reason to change
- **OCP:** Open for extension, closed for modification
- **LSP:** Subtypes substitutable for base types
- **ISP:** Narrow, client-specific interfaces
- **DIP:** Depend on abstractions, not implementations

---

## Shell Script-Specific Guidelines

Since agent-sandbox is primarily Bash, these additional rules apply:

### Script Structure
- `set -euo pipefail` at top of every script
- ShellCheck clean (no warnings without documented exceptions)
- Functions use `local` for all variables
- Quote all variable expansions

### Function Design
- Single responsibility per function
- Return values via stdout, errors via stderr
- Use `|| return 1` or `|| exit 1` for error propagation
- Document expected inputs/outputs in comments

### Security
- Never use `eval`
- Validate all external input before use
- Use `mktemp` for temporary files with proper cleanup
- Set restrictive permissions (umask 077) for sensitive files

---

## Framework References

- NIST SP 800-53 Rev 5.2.0
- NIST SP 800-218A (SSDF for Generative AI)
- OWASP Top 10 for LLM Applications 2025
- CISA Secure by Design Principles

---

## Version History

| Date | Version | Change |
|------|---------|--------|
| 2026-02-27 | 0.1.0 | Initial adoption from federal-agentic-ai-guidance |
