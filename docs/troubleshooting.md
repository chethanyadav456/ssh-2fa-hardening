# SSH 2FA Hardening Troubleshooting Guide

Troubleshooting guide for setup, validation, and rollback issues in the ssh-2fa-hardening framework.

## Troubleshooting Guide

Troubleshooting guide for setup, validation, and rollback issues in the ssh-2fa-hardening framework.

## Quick Triage Flow

1. Keep current SSH session open.
2. Run `sudo bash verify.sh`.
3. Run `sudo sshd -t`.
4. Check SSH service state (`systemctl status sshd` or `systemctl status ssh`).
5. If locked out risk increases, execute `sudo bash rollback.sh` from active session.

## Common Issues

### Package Installation Fails

Symptoms:

* Dependency install exits with repository or DNS errors

Actions:

* Verify internet and DNS resolution from host
* Confirm package mirrors for distro are healthy
* Retry after running package metadata update manually

### Google Authenticator Command Missing

Symptoms:

* `google-authenticator: command not found`

Actions:

* Debian/Ubuntu: ensure `libpam-google-authenticator` installed
* RHEL/CentOS: ensure `google-authenticator` package installed
* Re-run `setup.sh` after package fix

### QR Code Not Rendering

Symptoms:

* QR output blank or unreadable

Actions:

* Ensure terminal supports UTF-8 rendering
* Verify `qrencode` installed
* Use "Show QR again" option in script prompt
* If needed, import OTP URI manually from terminal output

### SSHD Validation Failure

Symptoms:

* `sshd -t` returns non-zero and restart is blocked

Actions:

* Run `sudo sshd -t` to capture exact error
* Check `/etc/ssh/sshd_config` for conflicting duplicated directives
* Restore using `rollback.sh` if immediate recovery needed
* Re-run `setup.sh` after resolving unsupported directives

### Locked Out After Restart

Symptoms:

* New SSH sessions denied after hardening

Actions:

* Use existing active session immediately
* Run `sudo bash rollback.sh`
* Confirm service healthy and login restored
* Re-attempt hardening with staged validation

### PAM Module Errors in Auth Logs

Symptoms:

* Login prompts appear but OTP validation fails

Actions:

* Confirm target user's `~/.google_authenticator` exists and permissions are strict
* Check `/var/log/auth.log` or `/var/log/secure` for PAM errors
* Re-run authenticator enrollment for user

### Service Name Mismatch (`ssh` vs `sshd`)

Symptoms:

* Restart or status command fails due to wrong unit name

Actions:

* Confirm available unit names with `systemctl list-unit-files | grep -E 'ssh|sshd'`
* Framework auto-detects name, but manual operations should use detected unit

## Recovery Commands

Verification:

```bash
sudo bash verify.sh
```

Rollback latest snapshot:

```bash
sudo bash rollback.sh
```

Rollback specific snapshot:

```bash
sudo bash rollback.sh /var/backups/ssh-2fa-hardening/<timestamp>
```

## Operational Safety Notes

* Never harden SSH on remote host without fallback access path
* Keep secondary terminal session active during all restarts
* Test fresh login before ending maintenance session
