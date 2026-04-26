#!/usr/bin/env bash

set -euo pipefail

FRAMEWORK_NAME="ssh-2fa-hardening"
BACKUP_ROOT="/var/backups/${FRAMEWORK_NAME}"
STATE_FILE="/var/lib/${FRAMEWORK_NAME}/last-run.env"

COLOR_RESET="\033[0m"
COLOR_BLUE="\033[0;34m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"

log_info() {
  printf "%b[INFO]%b %s\n" "$COLOR_BLUE" "$COLOR_RESET" "$1"
}

log_warn() {
  printf "%b[WARN]%b %s\n" "$COLOR_YELLOW" "$COLOR_RESET" "$1"
}

log_error() {
  printf "%b[ERROR]%b %s\n" "$COLOR_RED" "$COLOR_RESET" "$1" >&2
}

log_success() {
  printf "%b[SUCCESS]%b %s\n" "$COLOR_GREEN" "$COLOR_RESET" "$1"
}

die() {
  log_error "$1"
  exit 1
}

require_root() {
  [[ "$EUID" -eq 0 ]] || die "Run as root or with sudo."
}

resolve_backup_dir() {
  local requested_dir="${1:-}"

  if [[ -n "$requested_dir" ]]; then
    [[ -d "$requested_dir" ]] || die "Requested backup directory not found: ${requested_dir}"
    echo "$requested_dir"
    return
  fi

  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    if [[ -n "${LAST_BACKUP_DIR:-}" && -d "${LAST_BACKUP_DIR}" ]]; then
      echo "$LAST_BACKUP_DIR"
      return
    fi
  fi

  local latest_dir
  latest_dir="$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -n1 || true)"
  [[ -n "$latest_dir" ]] || die "No backup directories found under ${BACKUP_ROOT}."
  echo "$latest_dir"
}

restore_files_from_manifest() {
  local backup_dir="$1"
  local manifest_file="${backup_dir}/manifest.tsv"
  [[ -f "$manifest_file" ]] || die "Manifest file missing in backup directory: ${manifest_file}"

  log_info "Restoring files from backup manifest: ${manifest_file}"
  while IFS=$'\t' read -r original backup; do
    [[ -n "$original" && -n "$backup" ]] || continue
    [[ -f "$backup" ]] || die "Backup payload missing: ${backup}"

    cp -a "$backup" "$original"
    log_info "Restored ${original}"
  done < "$manifest_file"

  log_success "Configuration files restored from backup set."
}

restart_ssh_service() {
  local service_name="${1:-}"

  if [[ -z "$service_name" ]]; then
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl list-unit-files | awk '{print $1}' | grep -qx 'sshd.service'; then
        service_name="sshd"
      elif systemctl list-unit-files | awk '{print $1}' | grep -qx 'ssh.service'; then
        service_name="ssh"
      fi
    elif command -v service >/dev/null 2>&1; then
      if service sshd status >/dev/null 2>&1; then
        service_name="sshd"
      elif service ssh status >/dev/null 2>&1; then
        service_name="ssh"
      fi
    fi
  fi

  [[ -n "$service_name" ]] || {
    log_warn "Could not auto-detect SSH service name. Skipping restart."
    return
  }

  if command -v sshd >/dev/null 2>&1; then
    sshd -t || die "sshd -t failed after restore. Investigate before service restart."
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart "${service_name}.service"
    systemctl status "${service_name}.service" --no-pager || true
  else
    service "$service_name" restart
    service "$service_name" status || true
  fi

  log_success "SSH service '${service_name}' restarted after rollback."
}

main() {
  require_root

  local backup_dir
  backup_dir="$(resolve_backup_dir "${1:-}")"

  log_warn "Rollback will restore SSH and PAM config from: ${backup_dir}"
  read -r -p "Type 'yes' to continue rollback: " confirm
  [[ "$confirm" == "yes" ]] || die "Rollback cancelled by operator."

  restore_files_from_manifest "$backup_dir"

  local service_name=""
  if [[ -f "$STATE_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    service_name="${LAST_SSH_SERVICE_NAME:-}"
  fi

  restart_ssh_service "$service_name"

  echo
  echo "WARNING:"
  echo "Do not close your current SSH session"
  echo "until you verify login from a second terminal."
  echo

  log_success "Rollback completed."
}

main "$@"
