# Security Policy

## About this repository

The `agentic-coding-quickstart` provides the `acq` sandbox tooling and setup
guidance for running AI coding agents in isolated environments. It is shell and
documentation — there is no hosted service, and it processes no user data.

Because of that, the security issues that matter here are things like: unsafe
example commands, a supply-chain problem in the tooling, credentials accidentally
committed to the repository, or a sandbox-isolation weakness in the `acq`
scripts.

## Reporting a vulnerability

**Please do not open a public issue for a security vulnerability.**

1. **Preferred — GitHub private Security Advisories.** Open a report from this
   repository's **Security → Report a vulnerability** tab. This keeps the details
   private while we look into them.
2. **Email.** If you can't use Security Advisories, email
   **agentic-coding@gsa.gov** with the subject prefixed `[SECURITY]`.

Please include what you found, where (file, path, or command), and how to
reproduce it.

## Scope

This policy covers **this repository's own content and tooling**. These repos are
**out of scope** for GSA's official Vulnerability Disclosure Policy. If your
report concerns an actual GSA system or service (rather than this repository),
please use GSA's Vulnerability Disclosure Policy instead:
<https://www.gsa.gov/website-information/vulnerability-disclosure-policy>.

## What to expect

We're a small maintainer team, and we take security reports seriously. We'll
acknowledge your report as soon as we reasonably can, and we'll keep you posted
as we look into it. We can't commit to a formal response timeline, but we
genuinely appreciate you taking the time to help — thank you for making this
project better and safer for everyone who uses it.

## A note on licensing

This project is dedicated to the public domain under
[CC0 1.0 Universal](./LICENSE).
