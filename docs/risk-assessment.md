---
title: "AI Agent Risk Assessment Worksheet"
description: "Structured risk assessment template aligned with NIST AI RMF — threat analysis, control assessment, and sign-off"
status: canonical
tier: 3
last_updated: "2026-02-25"
nist_controls: ["RA-3", "RA-5"]
frameworks: ["NIST AI RMF 1.0", "OWASP Top 10 LLM 2025", "OWASP Top 10 Agentic 2026"]
audience: "isso"
keywords: ["risk-assessment", "AI-RMF", "threat-analysis", "OWASP", "ATO"]
related_files: ["docs/SECURITY-CONTROLS.md", "docs/AGENT-IDENTITY.md"]
load_priority: "reference-only"
review_cycle: "semi-annually"
---

<!-- LOAD: reference-only — Load only when performing a risk assessment or preparing ATO documentation. -->

# AI Agent Risk Assessment Worksheet

<!--
  INSTRUCTIONS:
  1. Complete this worksheet before deploying an AI coding agent in your project
  2. Review with your ISSO (Information System Security Officer) or equivalent
  3. Update when the agent, system, or environment changes materially
  4. Retain completed assessments as part of your ATO documentation

  Based on: Agentic Coding Playbook v0.4.0
  Aligned with: NIST AI RMF 1.0 (GOVERN, MAP, MEASURE, MANAGE)
  NIST SP 800-53: RA-3 (Risk Assessment)
-->

---

## Section 1: System Identification

| Field | Value |
|-------|-------|
| **System Name** | |
| **System Owner** | |
| **ISSO** | |
| **FIPS Impact Level** | [ ] Low [ ] Moderate [ ] High |
| **ATO Status** | [ ] Active [ ] In process [ ] Pre-ATO |
| **Assessment Date** | |
| **Assessor Name/Title** | |
| **Next Review Date** | |

---

## Section 2: AI Agent Identification

<!-- AI RMF: MAP 1 (Context is Established) -->

| Field | Value |
|-------|-------|
| **Agent Name/Product** | |
| **Agent Version** | |
| **Agent Vendor** | |
| **Deployment Model** | [ ] Local (runs on developer machine) [ ] Cloud SaaS [ ] Self-hosted |
| **FedRAMP Status** | [ ] Authorized [ ] In process [ ] Not applicable [ ] Unknown |
| **Data Residency** | [ ] US only [ ] International [ ] Unknown |
| **Training Data Opt-Out** | [ ] Confirmed opt-out [ ] Opt-out not available [ ] Unknown |

### Agent Capabilities

Check all capabilities the agent will use in this project:

- [ ] Code generation and modification
- [ ] File system read access
- [ ] File system write access
- [ ] Command/shell execution
- [ ] Network access (external)
- [ ] Network access (internal)
- [ ] Database access
- [ ] Git operations (commit, push)
- [ ] CI/CD pipeline interaction
- [ ] Package/dependency installation
- [ ] Infrastructure management
- [ ] Other: _______________

---

## Section 3: Data Classification

<!-- AI RMF: MAP 5 (Impacts to Individuals, Groups, Communities) -->
<!-- NIST SP 800-53: RA-2 (Security Categorization) -->

### 3.1 Data Types Accessible to the Agent

| Data Type | Present? | Classification | Agent Needs Access? |
|-----------|----------|---------------|-------------------|
| Source code | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| Configuration files | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| Environment variables | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| API keys/tokens/secrets | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| PII (names, SSN, etc.) | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| PHI (health records) | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| Financial data | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| CUI (Controlled Unclassified) | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| Classified data | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| Internal network info | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| User credentials | [ ] Yes [ ] No | | [ ] Yes [ ] No |
| Test/sample data | [ ] Yes [ ] No | | [ ] Yes [ ] No |

### 3.2 Data Flow

Where does data go when the agent processes it?

| Destination | Authorized? | Encrypted? |
|------------|-------------|------------|
| Agent vendor cloud (prompts/code) | [ ] Yes [ ] No | [ ] Yes [ ] No |
| Agent vendor training pipeline | [ ] Yes [ ] No [ ] Opted out | N/A |
| Local file system | [ ] Yes [ ] No | [ ] Yes [ ] No |
| Version control (remote) | [ ] Yes [ ] No | [ ] Yes [ ] No |
| CI/CD system | [ ] Yes [ ] No | [ ] Yes [ ] No |
| External APIs | [ ] Yes [ ] No | [ ] Yes [ ] No |
| Log aggregation system | [ ] Yes [ ] No | [ ] Yes [ ] No |

---

## Section 4: Threat Analysis

<!-- AI RMF: MAP 2 (Categorization of AI System), MEASURE 1 (Metrics) -->
<!-- Aligned with: OWASP Top 10 for LLM Applications 2025, OWASP Top 10 for Agentic Applications 2026 -->

Rate each threat for your specific deployment. **Likelihood**: 1 (Rare) to 5 (Almost Certain). **Impact**: 1 (Negligible) to 5 (Severe). **Risk = Likelihood x Impact**.

| # | Threat | OWASP Ref | Likelihood (1-5) | Impact (1-5) | Risk Score | Existing Mitigations | Residual Risk |
|---|--------|-----------|-------------------|--------------|------------|---------------------|---------------|
| T1 | **Prompt injection** — Malicious input causes agent to take unauthorized actions | LLM01, Agentic-01 | | | | | |
| T2 | **Sensitive data disclosure** — Agent exposes secrets, PII, or CUI in output | LLM02 | | | | | |
| T3 | **Supply chain compromise** — Agent installs malicious or vulnerable dependency | LLM03, Agentic-07 | | | | | |
| T4 | **Insecure code generation** — Agent produces code with vulnerabilities (SQLi, XSS, etc.) | LLM05 | | | | | |
| T5 | **Excessive agency** — Agent performs actions beyond intended scope | LLM06, Agentic-06 | | | | | |
| T6 | **Credential compromise** — Agent token or credentials are exposed or stolen | Agentic-02 | | | | | |
| T7 | **Unauthorized code execution** — Agent executes untrusted code from external source | Agentic-03 | | | | | |
| T8 | **Context/memory poisoning** — Agent's context is manipulated to influence behavior | Agentic-08 | | | | | |
| T9 | **Audit trail gaps** — Agent actions cannot be reconstructed from logs | Agentic-02 | | | | | |
| T10 | **Human trust exploitation** — User over-trusts agent output without review | Agentic-05 | | | | | |

### Risk Tolerance

| Risk Level | Score Range | Action Required |
|-----------|-------------|-----------------|
| **Critical** | 20-25 | MUST mitigate before agent deployment |
| **High** | 12-19 | MUST mitigate within 30 days of deployment |
| **Medium** | 6-11 | SHOULD mitigate; document accepted risk if deferred |
| **Low** | 1-5 | MAY accept with documentation |

---

## Section 5: Control Assessment

<!-- AI RMF: MANAGE 1 (Risk Treatments), MANAGE 2 (Risk Treatments Managed) -->

For each control area, assess your current implementation status.

| Control Area | Status | Notes |
|-------------|--------|-------|
| **Agent Identity** — Agent has distinct identity, separate from user | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Least Privilege** — Agent permissions scoped to minimum required | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Human-in-the-Loop** — Destructive/sensitive actions require approval | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Audit Logging** — All agent actions logged with attribution | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Secrets Scanning** — Pre-commit hooks prevent credential leaks | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **SAST/SCA** — Agent code scanned for vulnerabilities in CI | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Branch Protection** — Agent cannot push directly to protected branches | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Dependency Scanning** — Agent-installed packages scanned for CVEs | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Session Management** — Agent sessions timeout, no credential persistence | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Incident Response** — IR plan covers agent-specific scenarios | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Data Handling** — Agent cannot access/transmit unauthorized data | [ ] Implemented [ ] Partial [ ] Not implemented | |
| **Configuration Management** — Agent config version-controlled, reviewed | [ ] Implemented [ ] Partial [ ] Not implemented | |

---

## Section 6: Risk Treatment Plan

For each risk rated Medium or above, document the treatment plan.

### Risk: [T# — Threat Name]

| Field | Value |
|-------|-------|
| **Risk Score** | |
| **Treatment** | [ ] Mitigate [ ] Transfer [ ] Accept [ ] Avoid |
| **Planned Controls** | |
| **Responsible Party** | |
| **Target Completion** | |
| **Verification Method** | |

*(Copy this block for each risk requiring treatment)*

---

## Section 7: Acceptance and Sign-Off

### Risk Acceptance Statement

Based on this assessment, the residual risk of deploying [Agent Name] in [System Name] is:

[ ] **Acceptable** — Proceed with deployment under the documented controls
[ ] **Conditionally Acceptable** — Proceed after completing the risk treatment plan items marked as pre-deployment requirements
[ ] **Not Acceptable** — Do not deploy until identified risks are mitigated

### Signatures

| Role | Name | Signature | Date |
|------|------|-----------|------|
| **System Owner** | | | |
| **ISSO** | | | |
| **Authorizing Official** (if required) | | | |

---

## Appendix: Revision History

| Date | Version | Assessor | Changes |
|------|---------|----------|---------|
| | 1.0 | | Initial assessment |
