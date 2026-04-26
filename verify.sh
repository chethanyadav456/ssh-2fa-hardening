#!/usr/bin/env bash

set -euo pipefail

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=""
FAILURES=0

COLOR_RESET="\033[0m"
COLOR_BLUE="\033[0;34m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"

info() {
  printf "%b[INFO]%b %s\n" "$COLOR_BLUE" "$COLOR_RESET" "$1"
}

pass() {
  printf "%b[PASS]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

warn() {
  printf "%b[WARN]%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$1"
}

fail() {
  printf "%b[FAIL]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$1"
  FAILURES=$((FAILURES + 1))
}

resolve_target_home() {
  TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
  [[ -n "$TARGET_HOME" ]] || TARGET_HOME="/root"
}

check_packages() {
  info "Checking package availability."
  local missing=0

  if ! command -v google-authenticator >/dev/null 2>&1; then
    fail "google-authenticator binary missing"
    missing=1
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    fail "qrencode binary missing"
    missing=1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    fail "curl binary missing"
    missing=1
  fi

  if ! command -v wget >/dev/null 2>&1; then
    fail "wget binary missing"
    missing=1
  fi

  [[ "$missing" -eq 0 ]] && pass "Required package binaries detected"
}

check_google_auth_state() {
  local secret_file="${TARGET_HOME}/.google_authenticator"
  if [[ -f "$secret_file" ]]; then
    pass "Google Authenticator secret file present for ${TARGET_USER}"
  else
    fail "Google Authenticator secret file missing for ${TARGET_USER}"
  fi
}

check_pam_config() {
  local pam_file="/etc/pam.d/sshd"
  if grep -Eq '^\s*auth\s+required\s+pam_google_authenticator\.so' "$pam_file"; then
    pass "PAM sshd config includes pam_google_authenticator"
  else
    fail "PAM sshd config missing required pam_google_authenticator line"
  fi
}

check_sshd_directive() {
  local key="$1"
  local expected="$2"
  local file="/etc/ssh/sshd_config"

  if grep -Eq "^\s*${key}\s+${expected}\s*$" "$file"; then
    pass "${key} ${expected}"
  else
    fail "Expected '${key} ${expected}' not found in sshd_config"
  fi
}

check_authentication_methods() {
  local file="/etc/ssh/sshd_config"
  if grep -Eq '^\s*AuthenticationMethods\s+publickey,keyboard-interactive\s*$' "$file"; then
    pass "AuthenticationMethods publickey,keyboard-interactive"
  elif grep -Eq '^\s*AuthenticationMethods\s+password,keyboard-interactive\s*$' "$file"; then
    warn "Fallback AuthenticationMethods password,keyboard-interactive in use"
  else
    fail "AuthenticationMethods is not set to supported 2FA-safe values"
  fi
}

check_sshd_syntax() {
  if sshd -t >/dev/null 2>&1; then
    pass "sshd -t validation passed"
  else
    fail "sshd -t validation failed"
  fi
}

check_ssh_service_status() {
  local service_name=""
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files | awk '{print $1}' | grep -qx 'sshd.service'; then
      service_name="sshd"
    elif systemctl list-unit-files | awk '{print $1}' | grep -qx 'ssh.service'; then
      service_name="ssh"
    fi

    if [[ -n "$service_name" ]]; then
      if systemctl is-active --quiet "${service_name}.service"; then
        pass "${service_name}.service is active"
      else
        fail "${service_name}.service is not active"
      fi

      if systemctl is-enabled --quiet "${service_name}.service"; then
        pass "${service_name}.service is enabled"
      else
        warn "${service_name}.service is not enabled"
      fi
    else
      fail "Could not identify ssh/sshd service via systemctl"
    fi
  else
    if service sshd status >/dev/null 2>&1 || service ssh status >/dev/null 2>&1; then
      pass "SSH service appears running (service command)"
    else
      fail "Could not verify SSH service status"
    fi
  fi
}

main() {
  resolve_target_home
  info "Running SSH 2FA hardening verification checks for user ${TARGET_USER}."

  check_packages
  check_google_auth_state
  check_pam_config
  check_sshd_directive "ChallengeResponseAuthentication" "yes"
  check_sshd_directive "UsePAM" "yes"
  check_sshd_directive "PasswordAuthentication" "yes"
  check_authentication_methods
  check_sshd_syntax
  check_ssh_service_status

  if [[ "$FAILURES" -gt 0 ]]; then
    printf "\nVerification completed with %d failure(s).\n" "$FAILURES"
    exit 1
  fi

  printf "\nAll verification checks passed.\n"
}

main "$@"
