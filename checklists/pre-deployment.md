---
title: "Pre-Deployment Security Checklist"
description: "62-item security checklist for deploying AI-assisted code — secrets, input validation, auth, dependencies, testing, infrastructure, accessibility"
status: canonical
tier: 3
last_updated: "2026-02-25"
nist_controls: ["SA-11", "SA-12", "CM-2", "SI-10", "IA-5", "SC-13", "AU-2"]
frameworks: ["NIST SP 800-53 Rev 5.2", "OWASP Top 10 LLM 2025", "OWASP Top 10 Agentic 2026"]
audience: "developers"
keywords: ["checklist", "pre-deployment", "security-review", "sign-off"]
related_files: ["docs/CODING_PRACTICES.md", "docs/SECURITY-CONTROLS.md"]
load_priority: "reference-only"
review_cycle: "semi-annually"
---

<!-- LOAD: reference-only — Load only when preparing for deployment or running the pre-deployment checklist. -->

# Pre-Deployment Security Checklist for AI-Assisted Code

<!--
  INSTRUCTIONS:
  1. Complete this checklist before deploying any code that was generated or modified with AI agent assistance
  2. Every item must be marked Pass, Fail, or N/A with justification
  3. All Fail items must be resolved before deployment to production
  4. Retain completed checklists as part of your deployment records
  5. The reviewer completing this checklist MUST NOT be the same person who directed the agent

  Based on: Agentic Coding Playbook v0.4.0
  Aligned with: NIST SP 800-53 Rev 5.2, OWASP Top 10 for LLM/Agentic Applications
-->

---

## Deployment Information

| Field | Value |
|-------|-------|
| **System Name** | |
| **Release/Version** | |
| **Deployment Date** | |
| **Reviewer Name** | |
| **AI Agent Used** | |
| **Agent-Authored Files** | (list files or "see PR #___") |

---

## 1. Code Review and Provenance

<!-- NIST SP 800-53: SA-11, SA-15, CM-3 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 1.1 | All AI-generated code has been reviewed by a human (not the person who prompted the agent) | [ ] Pass [ ] Fail [ ] N/A | |
| 1.2 | AI-generated code is attributed in commit history (Co-Authored-By or equivalent) | [ ] Pass [ ] Fail [ ] N/A | |
| 1.3 | All changes went through the standard pull request / code review process | [ ] Pass [ ] Fail [ ] N/A | |
| 1.4 | No code was committed directly to protected branches (bypassing review) | [ ] Pass [ ] Fail [ ] N/A | |
| 1.5 | Reviewer understands what the code does and verified it matches the intended behavior | [ ] Pass [ ] Fail [ ] N/A | |

---

## 2. Secrets and Credentials

<!-- NIST SP 800-53: IA-5, SC-28 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 2.1 | No secrets, API keys, tokens, or passwords in source code | [ ] Pass [ ] Fail [ ] N/A | |
| 2.2 | No secrets in configuration files committed to version control | [ ] Pass [ ] Fail [ ] N/A | |
| 2.3 | No secrets in CI/CD pipeline definitions (use CI system's secrets management) | [ ] Pass [ ] Fail [ ] N/A | |
| 2.4 | No internal hostnames, IPs, or network topology exposed in code or config | [ ] Pass [ ] Fail [ ] N/A | |
| 2.5 | Pre-commit secrets scanning hook is active and passing | [ ] Pass [ ] Fail [ ] N/A | |
| 2.6 | All credentials are sourced from approved secrets management system | [ ] Pass [ ] Fail [ ] N/A | |

---

## 3. Input Validation and Output Encoding

<!-- NIST SP 800-53: SI-10, SI-15 -->
<!-- OWASP LLM: LLM01 (Prompt Injection), LLM05 (Improper Output Handling) -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 3.1 | All external input is validated (type, length, format, range) | [ ] Pass [ ] Fail [ ] N/A | |
| 3.2 | SQL queries use parameterized statements (no string concatenation) | [ ] Pass [ ] Fail [ ] N/A | |
| 3.3 | Output is encoded appropriately for context (HTML, JS, URL, shell) | [ ] Pass [ ] Fail [ ] N/A | |
| 3.4 | File path inputs are validated against path traversal attacks | [ ] Pass [ ] Fail [ ] N/A | |
| 3.5 | No use of eval(), innerHTML, or equivalent unsafe APIs with untrusted data | [ ] Pass [ ] Fail [ ] N/A | |
| 3.6 | Redirect URLs validated against an allowlist | [ ] Pass [ ] Fail [ ] N/A | |

---

## 4. Authentication and Authorization

<!-- NIST SP 800-53: IA-2, AC-3, AC-6 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 4.1 | All protected endpoints require authentication | [ ] Pass [ ] Fail [ ] N/A | |
| 4.2 | Authorization checks enforced server-side on every request | [ ] Pass [ ] Fail [ ] N/A | |
| 4.3 | Principle of least privilege applied (no excessive permissions) | [ ] Pass [ ] Fail [ ] N/A | |
| 4.4 | Session management uses secure defaults (timeouts, secure flags) | [ ] Pass [ ] Fail [ ] N/A | |
| 4.5 | No hardcoded roles or bypasses in authorization logic | [ ] Pass [ ] Fail [ ] N/A | |

---

## 5. Dependency Security

<!-- NIST SP 800-53: SA-12, SR-3 -->
<!-- OWASP LLM: LLM03 (Supply Chain), OWASP Agentic: Supply Chain Vulnerabilities -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 5.1 | All dependencies pinned to exact versions | [ ] Pass [ ] Fail [ ] N/A | |
| 5.2 | Lock file committed and matches installed versions | [ ] Pass [ ] Fail [ ] N/A | |
| 5.3 | No known critical or high vulnerabilities in dependencies | [ ] Pass [ ] Fail [ ] N/A | |
| 5.4 | All new dependencies reviewed for license compatibility | [ ] Pass [ ] Fail [ ] N/A | |
| 5.5 | Package names verified (no typosquatting) | [ ] Pass [ ] Fail [ ] N/A | |
| 5.6 | Dependency vulnerability scanning enabled in CI/CD | [ ] Pass [ ] Fail [ ] N/A | |
| 5.7 | SBOM generated or updated (if required by agency policy) | [ ] Pass [ ] Fail [ ] N/A | |

---

## 6. Error Handling and Logging

<!-- NIST SP 800-53: AU-2, AU-3, SI-11 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 6.1 | All errors handled explicitly (no empty catch blocks) | [ ] Pass [ ] Fail [ ] N/A | |
| 6.2 | Error messages do not expose internal details to users (stack traces, paths, SQL) | [ ] Pass [ ] Fail [ ] N/A | |
| 6.3 | Sensitive data (PII, secrets, tokens) excluded from log output | [ ] Pass [ ] Fail [ ] N/A | |
| 6.4 | Audit logging covers authentication, authorization, and data access events | [ ] Pass [ ] Fail [ ] N/A | |
| 6.5 | Log format is structured (JSON) with required fields (timestamp, user, action, result) | [ ] Pass [ ] Fail [ ] N/A | |

---

## 7. Cryptography and Data Protection

<!-- NIST SP 800-53: SC-13, SC-28, SC-8 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 7.1 | All network communication uses TLS 1.2 or later | [ ] Pass [ ] Fail [ ] N/A | |
| 7.2 | TLS certificate validation is enabled (not disabled or bypassed) | [ ] Pass [ ] Fail [ ] N/A | |
| 7.3 | Cryptographic algorithms are current and FIPS-validated where required | [ ] Pass [ ] Fail [ ] N/A | |
| 7.4 | No custom cryptographic implementations | [ ] Pass [ ] Fail [ ] N/A | |
| 7.5 | Sensitive data encrypted at rest using approved methods | [ ] Pass [ ] Fail [ ] N/A | |
| 7.6 | No cryptographic keys or IVs hardcoded in source | [ ] Pass [ ] Fail [ ] N/A | |

---

## 8. API and Network Security

<!-- NIST SP 800-53: SC-7, AC-4 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 8.1 | API endpoints authenticated (no unprotected state-changing endpoints) | [ ] Pass [ ] Fail [ ] N/A | |
| 8.2 | Rate limiting implemented on public/semi-public endpoints | [ ] Pass [ ] Fail [ ] N/A | |
| 8.3 | CORS configured with explicit origin allowlist (no wildcard for auth APIs) | [ ] Pass [ ] Fail [ ] N/A | |
| 8.4 | Security headers configured (CSP, HSTS, X-Content-Type-Options, X-Frame-Options) | [ ] Pass [ ] Fail [ ] N/A | |
| 8.5 | No sensitive data in URL query parameters | [ ] Pass [ ] Fail [ ] N/A | |
| 8.6 | Request/response schemas validated | [ ] Pass [ ] Fail [ ] N/A | |

---

## 9. Testing

<!-- NIST SP 800-53: SA-11, CA-2 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 9.1 | Unit tests written for all new functionality | [ ] Pass [ ] Fail [ ] N/A | |
| 9.2 | All existing tests pass | [ ] Pass [ ] Fail [ ] N/A | |
| 9.3 | Error paths and edge cases tested (not just happy path) | [ ] Pass [ ] Fail [ ] N/A | |
| 9.4 | Static application security testing (SAST) scan passed | [ ] Pass [ ] Fail [ ] N/A | |
| 9.5 | Software composition analysis (SCA) scan passed | [ ] Pass [ ] Fail [ ] N/A | |
| 9.6 | AI-generated code specifically reviewed for hallucinated APIs or deprecated methods | [ ] Pass [ ] Fail [ ] N/A | |
| 9.7 | AI agent `Co-Authored-By` attribution present in commits (per AGENTS.md) | [ ] Pass [ ] Fail [ ] N/A | |
| 9.8 | Risk assessment document completed and reviewed (per `federal-risk-assessment` skill) | [ ] Pass [ ] Fail [ ] N/A | |

---

## 10. Infrastructure and Deployment

<!-- NIST SP 800-53: CM-2, CM-6, SA-10 -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 10.1 | Infrastructure changes version-controlled and reviewed | [ ] Pass [ ] Fail [ ] N/A | |
| 10.2 | No default credentials in deployment configuration | [ ] Pass [ ] Fail [ ] N/A | |
| 10.3 | Services configured with least-privilege IAM roles | [ ] Pass [ ] Fail [ ] N/A | |
| 10.4 | Logging and monitoring enabled for all deployed services | [ ] Pass [ ] Fail [ ] N/A | |
| 10.5 | Container images (if used) scanned and using minimal base images | [ ] Pass [ ] Fail [ ] N/A | |
| 10.6 | Deployment requires human approval gate for production | [ ] Pass [ ] Fail [ ] N/A | |

---

## 11. Accessibility

<!-- Section 508 (29 U.S.C. § 794d), WCAG 2.1 Level AA -->

| # | Check | Status | Notes |
|---|-------|--------|-------|
| 11.1 | All UI components meet WCAG 2.1 Level AA conformance (semantic HTML, color contrast, keyboard navigation, screen reader compatibility) | [ ] Pass [ ] Fail [ ] N/A | |
| 11.2 | Automated accessibility scan passed (axe-core, Lighthouse accessibility audit, or equivalent) | [ ] Pass [ ] Fail [ ] N/A | |

---

## Summary

| Category | Total Checks | Pass | Fail | N/A |
|----------|-------------|------|------|-----|
| 1. Code Review | 5 | | | |
| 2. Secrets | 6 | | | |
| 3. Input/Output | 6 | | | |
| 4. Auth | 5 | | | |
| 5. Dependencies | 7 | | | |
| 6. Error/Logging | 5 | | | |
| 7. Crypto/Data | 6 | | | |
| 8. API/Network | 6 | | | |
| 9. Testing | 8 | | | |
| 10. Infrastructure | 6 | | | |
| 11. Accessibility | 2 | | | |
| **Total** | **62** | | | |

---

## Deployment Decision

[ ] **Approved** — All checks pass or N/A. Proceed with deployment.
[ ] **Conditionally Approved** — Minor findings documented above. Proceed with deployment and remediate within [timeframe].
[ ] **Not Approved** — One or more Fail items must be resolved before deployment.

### Sign-Off

| Role | Name | Signature | Date |
|------|------|-----------|------|
| **Reviewer** | | | |
| **Developer** | | | |
| **Approver** (if required) | | | |

---

*Checklist version 0.1.0 — Based on Agentic Coding Playbook*
*Aligned with NIST SP 800-53 Rev 5.2, OWASP Top 10 LLM 2025, OWASP Top 10 Agentic 2026*
