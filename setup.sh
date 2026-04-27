#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME="setup.sh"
FRAMEWORK_NAME="ssh-2fa-hardening"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
BACKUP_ROOT="/var/backups/${FRAMEWORK_NAME}"
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
STATE_ROOT="/var/lib/${FRAMEWORK_NAME}"
STATE_FILE="${STATE_ROOT}/last-run.env"
MANIFEST_FILE="${BACKUP_DIR}/manifest.tsv"

TARGET_USER="${SUDO_USER:-root}"
TARGET_HOME=""
SSH_SERVICE_NAME=""
SERVICE_MANAGER=""
PKG_MANAGER=""
DISTRO_ID=""

SSHD_CONFIG="/etc/ssh/sshd_config"
PAM_SSHD="/etc/pam.d/sshd"
REQUIRED_PAM_LINE="auth required pam_google_authenticator.so"

COLOR_RESET="\033[0m"
COLOR_BLUE="\033[0;34m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[0;31m"
COLOR_GREEN="\033[0;32m"

ROLLBACK_CANDIDATE=0

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

print_banner() {
  printf "%b" "$COLOR_BLUE"
  cat <<'EOF'
  ____  ____  _   _    ____  _____ _        _   _    _    ____  ____  _____ _   _ ___ _   _  ____
 / ___|/ ___|| | | |  |___ \|  ___/ \      | | | |  / \  |  _ \|  _ \| ____| \ | |_ _| \ | |/ ___|
 \___ \\___ \| |_| |    __) | |_ / _ \     | |_| | / _ \ | |_) | | | |  _| |  \| || ||  \| | |  _
  ___) |___) |  _  |   / __/|  _/ ___ \    |  _  |/ ___ \|  _ <| |_| | |___| |\  || || |\  | |_| |
 |____/|____/|_| |_|  |_____|_|/_/   \_\   |_| |_/_/   \_\_| \_\____/|_____|_| \_|___|_| \_|\____|
EOF
  printf "%b" "$COLOR_RESET"
}

die() {
  log_error "$1"
  exit 1
}

on_error() {
  local exit_code="$?"
  local line_no="$1"
  log_error "Execution failed at line ${line_no} with exit code ${exit_code}."
  if [[ "$ROLLBACK_CANDIDATE" -eq 1 ]]; then
    log_warn "Failure occurred after backup stage. Use rollback.sh to restore last known-good config."
    log_warn "Latest backup directory: ${BACKUP_DIR}"
  fi
  exit "$exit_code"
}

trap 'on_error $LINENO' ERR

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root or with sudo."
  fi
}

detect_target_user_home() {
  TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
  if [[ -z "$TARGET_HOME" ]]; then
    die "Could not resolve home directory for target user: ${TARGET_USER}."
  fi
}

detect_distro_and_pkg_manager() {
  [[ -f /etc/os-release ]] || die "/etc/os-release missing. Unsupported system."

  # shellcheck disable=SC1091
  source /etc/os-release
  DISTRO_ID="${ID:-unknown}"

  case "$DISTRO_ID" in
    ubuntu|debian)
      PKG_MANAGER="apt"
      ;;
    rhel|centos|rocky|almalinux|fedora)
      if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
      elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
      else
        die "Neither dnf nor yum available on RPM-based system."
      fi
      ;;
    *)
      die "Unsupported distribution '${DISTRO_ID}'. Supported: Ubuntu, Debian, CentOS, RHEL family."
      ;;
  esac

  log_info "Detected distro '${DISTRO_ID}' with package manager '${PKG_MANAGER}'."
}

check_openssh_installed() {
  command -v sshd >/dev/null 2>&1 || die "OpenSSH server binary 'sshd' not found. Install openssh-server first."
}

check_internet_connectivity() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 8 https://www.google.com >/dev/null 2>&1 || die "No outbound internet connectivity detected."
  elif command -v wget >/dev/null 2>&1; then
    wget -q --spider --timeout=8 https://www.google.com || die "No outbound internet connectivity detected."
  else
    die "Neither curl nor wget found for connectivity check."
  fi
}

detect_service_manager() {
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files >/dev/null 2>&1; then
    SERVICE_MANAGER="systemctl"
  elif command -v service >/dev/null 2>&1; then
    SERVICE_MANAGER="service"
  else
    die "Neither systemctl nor service command found."
  fi
  log_info "Detected service manager: ${SERVICE_MANAGER}"
}

detect_ssh_service_name() {
  local candidate

  if [[ "$SERVICE_MANAGER" == "systemctl" ]]; then
    # Prefer ssh on Debian/Ubuntu, then sshd for RHEL-like systems.
    for candidate in ssh sshd; do
      if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "${candidate}.service"; then
        SSH_SERVICE_NAME="$candidate"
        break
      fi

      if [[ -f "/etc/systemd/system/${candidate}.service" || -f "/lib/systemd/system/${candidate}.service" || -f "/usr/lib/systemd/system/${candidate}.service" ]]; then
        SSH_SERVICE_NAME="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$SSH_SERVICE_NAME" ]] && command -v service >/dev/null 2>&1; then
    for candidate in ssh sshd; do
      if service "$candidate" status >/dev/null 2>&1 || [[ -x "/etc/init.d/${candidate}" ]]; then
        SSH_SERVICE_NAME="$candidate"
        break
      fi
    done
  fi

  if [[ -z "$SSH_SERVICE_NAME" ]] && command -v sshd >/dev/null 2>&1; then
    SSH_SERVICE_NAME="sshd"
    SERVICE_MANAGER="process"
    log_warn "No managed ssh service unit found. Falling back to direct sshd process management."
  fi

  [[ -n "$SSH_SERVICE_NAME" ]] || die "Unable to detect SSH service name (ssh/sshd)."
  log_info "Using SSH service: ${SSH_SERVICE_NAME}"
}

is_google_auth_already_configured() {
  [[ -f "${TARGET_HOME}/.google_authenticator" ]]
}

install_dependencies() {
  log_info "Installing required dependencies."
  case "$PKG_MANAGER" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt update -y
      apt install -y libpam-google-authenticator qrencode curl wget
      ;;
    yum)
      yum install -y google-authenticator qrencode curl wget
      ;;
    dnf)
      dnf install -y google-authenticator qrencode curl wget
      ;;
    *)
      die "Unsupported package manager '${PKG_MANAGER}'."
      ;;
  esac
  log_success "Dependencies installed."
}

ensure_backup_paths() {
  mkdir -p "$BACKUP_DIR"
  mkdir -p "$STATE_ROOT"
  : > "$MANIFEST_FILE"
}

backup_file() {
  local src="$1"
  [[ -f "$src" ]] || die "Cannot backup missing file: ${src}"

  local safe_name
  safe_name="$(echo "$src" | sed 's#/#__#g' | sed 's/^__//')"
  local dest="${BACKUP_DIR}/${safe_name}.bak"

  cp -a "$src" "$dest"
  printf "%s\t%s\n" "$src" "$dest" >> "$MANIFEST_FILE"
}

write_state_file() {
  cat > "$STATE_FILE" <<EOF
LAST_BACKUP_DIR=${BACKUP_DIR}
LAST_TARGET_USER=${TARGET_USER}
LAST_DISTRO_ID=${DISTRO_ID}
LAST_PKG_MANAGER=${PKG_MANAGER}
LAST_SERVICE_MANAGER=${SERVICE_MANAGER}
LAST_SSH_SERVICE_NAME=${SSH_SERVICE_NAME}
LAST_EXECUTION_TS=${TIMESTAMP}
EOF
}

show_qr_again() {
  local secret_file="${TARGET_HOME}/.google_authenticator"
  [[ -f "$secret_file" ]] || die "Google Authenticator secret file not found for ${TARGET_USER}."

  local secret
  secret="$(head -n1 "$secret_file")"
  [[ -n "$secret" ]] || die "Could not read TOTP secret from ${secret_file}."

  local label="${TARGET_USER}@$(hostname)"
  local issuer="SSH2FA-Hardening"
  local otp_uri="otpauth://totp/${label}?secret=${secret}&issuer=${issuer}"

  if command -v qrencode >/dev/null 2>&1; then
    printf "\n"
    qrencode -t ANSIUTF8 "$otp_uri"
    printf "\n"
  else
    log_warn "qrencode not available, cannot redraw QR."
    log_info "Use this URI manually in authenticator app: ${otp_uri}"
  fi
}

run_google_authenticator_setup() {
  if is_google_auth_already_configured; then
    log_warn "Google Authenticator already configured for ${TARGET_USER}."
    read -r -p "Do you want to reconfigure it? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
      log_info "Keeping existing authenticator configuration."
      return
    fi
  fi

  log_info "Launching interactive Google Authenticator setup for user ${TARGET_USER}."
  log_warn "Follow prompts carefully and store emergency scratch codes securely."
  sudo -u "$TARGET_USER" -H google-authenticator

  while true; do
    printf "\nHave you scanned the QR code?\n\n"
    printf "1. Yes, continue\n"
    printf "2. Show QR again\n"
    printf "3. Exit safely\n\n"
    read -r -p "Select option [1-3]: " option
    case "$option" in
      1)
        log_success "QR scan confirmed by operator."
        break
        ;;
      2)
        show_qr_again
        ;;
      3)
        log_warn "Operator requested safe exit before SSH mutation. No service changes applied."
        exit 0
        ;;
      *)
        log_warn "Invalid option. Choose 1, 2, or 3."
        ;;
    esac
  done
}

ensure_pam_line() {
  log_info "Configuring PAM for SSHD."
  backup_file "$PAM_SSHD"

  if grep -Eq '^\s*auth\s+required\s+pam_google_authenticator\.so' "$PAM_SSHD"; then
    log_info "PAM rule already present, no duplicate added."
    return
  fi

  local tmp_file
  tmp_file="$(mktemp)"
  {
    echo "$REQUIRED_PAM_LINE"
    cat "$PAM_SSHD"
  } > "$tmp_file"

  install -m 0644 "$tmp_file" "$PAM_SSHD"
  rm -f "$tmp_file"
  log_success "PAM configuration updated."
}

upsert_directive_in_file() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -Eq "^\s*${key}\s+" "$file"; then
    sed -i "s#^\s*${key}\s\+.*#${key} ${value}#" "$file"
  elif grep -Eq "^\s*#\s*${key}\s+" "$file"; then
    sed -i "s#^\s*#\s*${key}\s\+.*#${key} ${value}#" "$file"
  else
    printf "\n%s %s\n" "$key" "$value" >> "$file"
  fi
}

test_sshd_config_file() {
  local file="$1"
  sshd -t -f "$file" >/dev/null 2>&1
}

configure_sshd() {
  log_info "Configuring SSH daemon settings."
  backup_file "$SSHD_CONFIG"

  local tmp_file
  tmp_file="$(mktemp)"
  cp -a "$SSHD_CONFIG" "$tmp_file"

  upsert_directive_in_file "$tmp_file" "ChallengeResponseAuthentication" "yes"
  upsert_directive_in_file "$tmp_file" "UsePAM" "yes"
  upsert_directive_in_file "$tmp_file" "PasswordAuthentication" "yes"

  upsert_directive_in_file "$tmp_file" "AuthenticationMethods" "publickey,keyboard-interactive"
  if ! test_sshd_config_file "$tmp_file"; then
    log_warn "Preferred AuthenticationMethods unsupported. Falling back to password,keyboard-interactive."
    upsert_directive_in_file "$tmp_file" "AuthenticationMethods" "password,keyboard-interactive"
    test_sshd_config_file "$tmp_file" || die "Both AuthenticationMethods variants failed validation."
  fi

  install -m 0600 "$tmp_file" "$SSHD_CONFIG"
  rm -f "$tmp_file"
  log_success "SSHD configuration updated."
}

manage_ssh_service() {
  local action="$1"
  case "$action" in
    start|stop|restart|reload|enable|disable|status)
      ;;
    *)
      die "Unsupported service action '${action}'."
      ;;
  esac

  if [[ "$SERVICE_MANAGER" == "systemctl" ]]; then
    case "$action" in
      status)
        systemctl status "${SSH_SERVICE_NAME}.service" --no-pager
        ;;
      *)
        systemctl "$action" "${SSH_SERVICE_NAME}.service"
        ;;
    esac
  else
    if [[ "$SERVICE_MANAGER" == "service" ]]; then
      case "$action" in
        enable|disable)
          log_warn "Service manager '${SERVICE_MANAGER}' does not support ${action} consistently; skipping."
          ;;
        *)
          service "$SSH_SERVICE_NAME" "$action"
          ;;
      esac
    else
      case "$action" in
        reload|restart)
          pgrep -x sshd >/dev/null 2>&1 || die "sshd process not running; cannot ${action}."
          pkill -HUP -x sshd
          ;;
        status)
          pgrep -ax sshd || die "sshd process not running."
          ;;
        enable|disable)
          log_warn "Direct process mode does not support ${action}; skipping."
          ;;
        start|stop)
          die "Direct process mode does not support ${action} safely."
          ;;
        *)
          die "Unsupported service action '${action}' for direct process mode."
          ;;
      esac
    fi
  fi
}

final_sshd_validation() {
  log_info "Running final sshd configuration validation (sshd -t)."
  sshd -t || die "sshd -t failed. Restart blocked. Run rollback.sh or inspect config manually."
  log_success "sshd -t passed."
}

main() {
  print_banner

  if [[ "${1:-}" == "service" ]]; then
    local action="${2:-}"
    [[ -n "$action" ]] || die "Usage: sudo bash setup.sh service <start|stop|restart|reload|enable|disable|status>"

    require_root
    detect_service_manager
    detect_ssh_service_name
    manage_ssh_service "$action"
    exit 0
  fi

  log_info "Starting ${FRAMEWORK_NAME} security hardening workflow."

  require_root
  detect_target_user_home
  detect_distro_and_pkg_manager
  check_openssh_installed
  check_internet_connectivity
  detect_service_manager
  detect_ssh_service_name

  install_dependencies
  run_google_authenticator_setup

  ensure_backup_paths
  ROLLBACK_CANDIDATE=1

  ensure_pam_line
  configure_sshd
  final_sshd_validation
  write_state_file

  manage_ssh_service restart
  manage_ssh_service enable || true
  manage_ssh_service status || true

  echo
  echo "WARNING:"
  echo "Do not close your current SSH session"
  echo "until you verify login from a second terminal."
  echo

  log_success "SSH 2FA hardening completed successfully."
  log_info "Backup artifacts stored at: ${BACKUP_DIR}"
  log_info "Use rollback.sh if you need to restore previous configuration."
}

main "$@"
