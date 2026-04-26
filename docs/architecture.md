---
title: SSH 2FA Hardening Architecture
description: Technical architecture and execution model of the ssh-2fa-hardening automation framework.
author: chethanyadav456
ms.date: 2026-04-26
ms.topic: concept
keywords:
  - architecture
  - sshd
  - pam
  - hardening
estimated_reading_time: 7
---

## Architecture Summary

Technical architecture and execution model of the ssh-2fa-hardening automation framework.

## System Goal

Deliver safe, repeatable SSH 2FA hardening with strong operational guardrails and low outage risk.

## Design Principles

* Fail closed on pre-check and validation errors
* Mutate only after backup and explicit readiness gates
* Keep configuration idempotent and duplicate-safe
* Block daemon restart on invalid syntax
* Preserve recoverability through deterministic rollback artifacts

## Runtime Components

* `setup.sh`: Main orchestration pipeline
* `rollback.sh`: Configuration restore and service recovery
* `verify.sh`: Post-deployment policy and health checks
* `config/*.template`: Opinionated baseline references

## Execution Pipeline

1. Privilege and environment pre-checks
2. Distro and package-manager detection
3. Dependency installation (`google-authenticator`, `qrencode`, `curl`, `wget`)
4. Interactive user enrollment and QR confirmation loop
5. Backup snapshot + manifest creation
6. PAM rule enforcement (`pam_google_authenticator.so`)
7. SSH directives update with auth-method compatibility fallback
8. `sshd -t` hard validation gate
9. Controlled SSH service restart and status check
10. Operator safety warning for session continuity

## Backup and Rollback Model

Backups written to timestamped directories under `/var/backups/ssh-2fa-hardening/`.

Each run writes:

* `manifest.tsv`: Source-to-backup mapping
* Backed-up payload files (`/etc/ssh/sshd_config`, `/etc/pam.d/sshd`)
* State metadata in `/var/lib/ssh-2fa-hardening/last-run.env`

Rollback reads state and manifest, restores all tracked files, validates with `sshd -t`, and restarts detected SSH service.

## SSH Compatibility Strategy

Framework attempts stronger authentication chain first:

* `AuthenticationMethods publickey,keyboard-interactive`

If daemon rejects configuration during dry validation, framework falls back to:

* `AuthenticationMethods password,keyboard-interactive`

This preserves deployability across heterogeneous OpenSSH and policy baselines.

## Service Abstraction

Handles distro service naming differences:

* Daemon unit names: `ssh` or `sshd`
* Init control: `systemctl` preferred, `service` fallback
* Supported actions: `start`, `stop`, `restart`, `reload`, `enable`, `disable`, `status`

## Security Controls Summary

* Root-only execution
* Outbound connectivity pre-check
* OpenSSH presence validation
* No blind appends to PAM/SSHD config
* Backup-first mutation model
* Hard restart block on failed syntax checks
