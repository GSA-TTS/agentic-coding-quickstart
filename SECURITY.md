# Security Policy

## Scope

This repository is part of the **Agentic Coding Capability Assessment** — an internal GSA initiative. It contains:

- Documentation for setting up Docker Sandboxes (SBX) with USAi endpoints
- Configuration files for AI coding agents
- Templates for bootstrapping projects

There are no deployed services or production infrastructure in this repository.

## Reporting and Fixing Security Issues

This is an **internal assessment repository** with trusted contributors. The appropriate response to most issues is to fix them directly.

### For Content Issues

If you find content that could lead to insecure implementations (incorrect configuration, unsafe patterns, etc.):

1. **Submit a PR to fix it** — This is the preferred approach for internal repos
2. **Open an issue** if you're unsure how to fix it or want to discuss first
3. **Ask in the agentic-coding Slack channel** if you have questions or need help coordinating

### For Repository Infrastructure Issues

If you find a security issue with the repository infrastructure (CI/CD, GitHub Actions, dependencies, scripts):

1. **Submit a PR to fix it** — You have access, so fix it directly when possible
2. **Open an issue** to track the problem if you need help or it requires discussion
3. **Contact channel admins** if you're unsure about the right approach

Since this is an internal repository, formal security advisories are not required. Use your judgment — if something seems sensitive, discuss with channel admins before posting details publicly.

### For GSA Platform Issues (Outside This Repo)

For security concerns related to GSA systems, USAi platform, or other infrastructure outside the scope of this repository:

- **Follow your normal GSA security reporting processes**
- **Submit a ticket** or **email GSA security** as appropriate for your organization
- **USAi-specific issues:** Contact support@usai.gov

These repos are for the assessment — platform and infrastructure security follows standard GSA procedures.

## Security Best Practices

When using this repository:

1. **Never commit secrets** — API keys, tokens, and credentials belong in environment variables
2. **Use SBX isolation** — Run AI agents inside Docker Sandboxes, not on your host system
3. **Follow AGENTS.md rules** — The behavioral contract helps prevent unsafe agent actions
4. **Review agent output** — AI-generated code requires human review before production use

## Supported Versions

This is an active assessment project. Security updates are applied to the `main` branch only.

---

**Last Updated:** 2026-05-21
