# Security Policy — Network Monitor

## Supported version and reporting
Security updates apply to the default branch. Report issues privately with GitHub's vulnerability reporting (if enabled) or via the maintainer's private GitHub contact. Do not post real MAC/IP inventories, usernames, or host details publicly.

## Controls for this project
- **Privacy / GRC:** Baselines and logs contain device MAC addresses, IP addresses, hostnames and presence times. Keep them local, restrict file access, set a retention policy, and anonymize sample data.
- **Network safety:** Monitor only networks you administer or have permission to observe. Preserve non-destructive ARP/neighbor-table collection and bounded sweeps; no unauthorized active intervention.
- **IAM:** The tool has no user directory or login system. Use OS file permissions and least-privileged execution; do not hard-code remote credentials.
- **Cloud:** No cloud collection is required. Any future alert transport must encrypt traffic, avoid publishing inventories, use scoped tokens and define retention.
- **AI / OT:** Do not add autonomous blocking, industrial-network interaction, or AI-triggered responses without a separate safety and authorization assessment.

## Verification
Keep the existing Bash and PowerShell lint/tests passing. Check the behavior of baseline creation, log/output paths, race conditions, error handling, and accidental disclosure before release.
