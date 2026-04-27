<p align="center">
    <img src="logo.png" alt="SSH 2FA Hardening Framework logo" width="350" />
</p>

<p align="center">
    <strong>Enterprise-grade automation framework to harden Linux SSH access with Google Authenticator PAM-based two-factor authentication.</strong>
</p>

## SSH 2FA Hardening Framework

Enterprise-grade automation framework for hardening Linux SSH access with PAM-based Google Authenticator 2FA. Project designed for production rollout, safe rollback, and repeatable validation across mixed Linux environments.

## Why This Matters

Password-only SSH remains high-risk under modern threat models:

* Credential stuffing and leaked password reuse
* Brute-force and distributed guessing attacks
* Lateral movement after endpoint compromise
* Weak credential hygiene in shared admin teams

2FA reduces blast radius by requiring possession factor in addition to password or key authentication.

## One-Line Deployment

```bash
curl -sSL https://raw.githubusercontent.com/chethanyadav456/ssh-2fa-hardening/refs/heads/main/setup.sh | sudo bash
```

```bash
wget -qO- https://raw.githubusercontent.com/chethanyadav456/ssh-2fa-hardening/refs/heads/main/setup.sh | sudo bash
```

## Features

* Strict bash safety (`set -euo pipefail`)
* Colored structured logs (`INFO`, `WARN`, `ERROR`, `SUCCESS`)
* OS and package-manager detection (`apt`, `yum`, `dnf`)
* Pre-flight validation checks before mutation
* Automatic timestamped backup strategy
* Interactive Google Authenticator enrollment with QR re-display flow
* Idempotent PAM and SSH config updates (no duplicate directives)
* Syntax-safe SSH validation via `sshd -t` before restart
* Cross-distro SSH service management abstraction (`ssh`/`sshd`)
* Dedicated verification and rollback tooling

## Repository Layout

```text
.
├── setup.sh
├── rollback.sh
├── verify.sh
├── config/
│   ├── pam_sshd.template
│   └── sshd_config.template
└── docs/
    ├── architecture.md
    └── troubleshooting.md
```

## Architecture Overview

Framework organized around controlled phases:

1. Pre-checks and dependency readiness
2. Interactive identity factor enrollment
3. PAM mutation with backup-aware idempotency
4. SSH daemon hardening with compatibility fallback
5. Syntax validation gate before service reload/restart
6. Post-change verification and operator warning flow

Detailed architecture: [docs/architecture.md](docs/architecture.md)

## Installation Guide

1. Clone repository or host `setup.sh` behind HTTPS.
2. Execute with root privileges.
3. Complete interactive Google Authenticator prompt.
4. Scan QR code from authenticator app.
5. Keep active SSH session open.
6. Validate access from second terminal before closing first session.

Local run:

```bash
sudo bash setup.sh
```

## Interactive QR Flow

Script enforces mandatory user confirmation after enrollment:

```text
Have you scanned the QR code?

1. Yes, continue
2. Show QR again
3. Exit safely
```

No bypass in production flow.

## Verification Steps

Run post-deployment validation:

```bash
sudo bash verify.sh
```

This checks:

* Package presence
* PAM line enforcement
* SSH hardening directives
* `sshd -t` config validity
* SSH service health

## Rollback Guide

Emergency rollback command:

```bash
sudo bash rollback.sh
```

Rollback script restores latest backup set from `/var/backups/ssh-2fa-hardening/` and attempts safe SSH service restart.

## Supported Operating Systems

* Ubuntu (apt)
* Debian (apt)
* CentOS (yum)
* RHEL (yum/dnf)


## Security Best Practices

* Keep one active SSH session during hardening
* Verify second session login before disconnecting first
* Prefer public key + keyboard-interactive mode where supported
* Restrict SSH exposure with firewall and trusted CIDRs
* Disable password auth later if key-only policy enforced
* Rotate recovery codes and monitor auth logs continuously

## Troubleshooting

Common failure modes and fixes: [docs/troubleshooting.md](docs/troubleshooting.md)

## Future Roadmap

* Non-interactive bootstrap mode with pre-provisioned secret support
* SIEM-friendly JSON log mode
* OpenSCAP integration for compliance evidence
* Ansible role and Terraform external data wrapper
* Optional FIDO2/U2F PAM pathway
