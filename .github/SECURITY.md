# Security policy

Vibe Manager launches coding agents and shells, reads their transcripts and holds access to the
folders you give it. A flaw in any of that matters, so please report it privately first.

## Supported versions

Only the latest release receives security fixes. The application updates itself through Sparkle;
check **Vibe Manager › Check for Updates…** before reporting.

## Reporting a vulnerability

Do not open a public issue. Use one of:

- GitHub's private vulnerability reporting:
  [Report a vulnerability](https://github.com/hadrienl/vibe-manager/security/advisories/new)
- Email: [hadrien@lanneau.me](mailto:hadrien@lanneau.me)

Include the version, the macOS version, what an attacker controls, what they gain, and the steps to
reproduce it. A proof of concept helps; it does not need to be polished.

## What to expect

- An acknowledgement within 7 days.
- An assessment, and a fix or a mitigation plan, as soon as the issue is confirmed.
- Credit in the release notes and the advisory, unless you prefer to stay anonymous.

Please give a reasonable delay for a fix to ship before disclosing anything publicly.

## Scope

In scope: the application, its terminal host, the way it launches processes and passes environment
to them, the local session store, the update feed and its signature checks.
[`docs/security-review.md`](../docs/security-review.md) inventories what the application runs and
reads.

Out of scope: vulnerabilities in the coding agents themselves (Claude Code, Codex…) or in macOS —
report those to their vendors.
