# Security policy

## Supported versions

Security fixes are provided for the latest tagged release. Pre-release builds are offered without long-term support guarantees.

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could expose credentials, execute code, delete unrelated data, or bypass enterprise policy. Use the repository's private security advisory feature when available, and include:

- affected version and Windows build;
- a minimal reproduction;
- expected and actual behavior;
- whether secrets or unrelated files/tasks can be affected;
- suggested mitigation, if known.

Do not include real proxy credentials, access tokens, usernames, public IPs, or unredacted logs. Maintainers should acknowledge a complete report within seven days and coordinate disclosure after a fix or mitigation is available.

## Design commitments

The project does not request elevation, change Windows/WinHTTP proxy settings, persist proxy environment variables, or collect telemetry. Release archives should be reproducible from the tagged source with `tools\Package-Release.ps1`; verify the published SHA-256 checksum before installation.
