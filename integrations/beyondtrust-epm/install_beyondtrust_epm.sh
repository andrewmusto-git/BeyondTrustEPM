#!/usr/bin/env bash
# install_beyondtrust_epm.sh — One-command installer for BeyondTrust EPM → Veza OAA integration
#
# Usage (interactive):
#   curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/integrations/beyondtrust-epm/install_beyondtrust_epm.sh | bash
#
# Usage (CI / non-interactive):
#   BT_URL=https://... BT_CLIENT_ID=... BT_CLIENT_SECRET=... \
#   VEZA_URL=https://... VEZA_API_KEY=... \
#   bash install_beyondtrust_epm.sh --non-interactive
#
# Flags:
#   --non-interactive   Skip prompts; read all values from env vars
#   --overwrite-env     Overwrite an existing .env file
#   --install-dir PATH  Override default install directory
#   --repo-url URL      Override GitHub repo URL for script download
#   --branch NAME       Override git branch (default: main)
# ---------------------------------------------------------------------------
set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SLUG="beyondtrust-epm"
SCRIPT_NAME="beyondtrust_epm.py"
INTEGRATION_SUBDIR="integrations/beyondtrust-epm"
DEFAULT_INSTALL_DIR="/opt/VEZA/beyondtrust-epm-veza"
SCRIPTS_DIR_NAME="scripts"
LOGS_DIR_NAME="logs"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=9

# Colours
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------
NON_INTERACTIVE=false
OVERWRITE_ENV=false
INSTALL_DIR="${DEFAULT_INSTALL_DIR}"
REPO_URL="${REPO_URL:-https://github.com/your-org/your-repo}"
BRANCH="${BRANCH:-main}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --non-interactive) NON_INTERACTIVE=true ;;
    --overwrite-env)   OVERWRITE_ENV=true ;;
    --install-dir)     INSTALL_DIR="$2"; shift ;;
    --repo-url)        REPO_URL="$2"; shift ;;
    --branch)          BRANCH="$2"; shift ;;
    *) warn "Unknown flag: $1" ;;
  esac
  shift
done

SCRIPTS_DIR="${INSTALL_DIR}/${SCRIPTS_DIR_NAME}"
LOGS_DIR="${INSTALL_DIR}/${LOGS_DIR_NAME}"

# ---------------------------------------------------------------------------
# Detect OS / package manager
# ---------------------------------------------------------------------------
OS_ID=""
PKG_MGR=""

if [[ -f /etc/os-release ]]; then
  OS_ID=$(grep -E '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')
fi

if   command -v dnf  &>/dev/null; then PKG_MGR="dnf"
elif command -v yum  &>/dev/null; then PKG_MGR="yum"
elif command -v apt-get &>/dev/null; then PKG_MGR="apt-get"
else warn "No supported package manager found (dnf/yum/apt-get). Manual dependency install may be needed."
fi

_install_pkg() {
  local pkg="$1"
  [[ -z "${PKG_MGR}" ]] && { warn "No package manager — skipping install of ${pkg}"; return; }
  info "Installing ${pkg} …"
  case "${PKG_MGR}" in
    dnf|yum) "${PKG_MGR}" install -y "${pkg}" >/dev/null ;;
    apt-get) apt-get install -y "${pkg}" >/dev/null ;;
  esac
}

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
info "Checking system dependencies …"

# git
command -v git &>/dev/null || _install_pkg git

# python3
command -v python3 &>/dev/null || _install_pkg python3

# pip
python3 -m pip --version &>/dev/null || {
  [[ "${OS_ID}" == "amzn" ]] && _install_pkg python3-pip || _install_pkg python3-pip
}

# curl (skip on Amazon Linux if curl-minimal already present)
if ! command -v curl &>/dev/null; then
  if [[ "${OS_ID}" == "amzn" ]]; then
    warn "Skipping curl install on Amazon Linux (curl-minimal conflict)"
  else
    _install_pkg curl
  fi
fi

# python3-venv
if ! python3 -m venv --help &>/dev/null; then
  case "${PKG_MGR}" in
    dnf|yum) _install_pkg python3-virtualenv ;;
    apt-get) _install_pkg python3-venv ;;
  esac
fi

# ---------------------------------------------------------------------------
# Python version check
# ---------------------------------------------------------------------------
PYTHON_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PYTHON_MAJOR=$(echo "${PYTHON_VER}" | cut -d. -f1)
PYTHON_MINOR=$(echo "${PYTHON_VER}" | cut -d. -f2)

if (( PYTHON_MAJOR < MIN_PYTHON_MAJOR || (PYTHON_MAJOR == MIN_PYTHON_MAJOR && PYTHON_MINOR < MIN_PYTHON_MINOR) )); then
  die "Python ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}+ required — found ${PYTHON_VER}"
fi
ok "Python ${PYTHON_VER} detected"

# ---------------------------------------------------------------------------
# Create directory layout
# ---------------------------------------------------------------------------
info "Creating install directories …"
mkdir -p "${SCRIPTS_DIR}" "${LOGS_DIR}"

# ---------------------------------------------------------------------------
# Clone repo and copy integration files
# ---------------------------------------------------------------------------
info "Cloning integration scripts from ${REPO_URL} (branch: ${BRANCH}) …"
TMP_DIR=$(mktemp -d)
GIT_TERMINAL_PROMPT=0 git clone --branch "${BRANCH}" --depth 1 --single-branch \
  "${REPO_URL}" "${TMP_DIR}" || die "git clone failed — check REPO_URL and BRANCH"

cp -f "${TMP_DIR}/${INTEGRATION_SUBDIR}/${SCRIPT_NAME}"     "${SCRIPTS_DIR}/"
cp -f "${TMP_DIR}/${INTEGRATION_SUBDIR}/requirements.txt"   "${SCRIPTS_DIR}/"
rm -rf "${TMP_DIR}"
ok "Scripts copied to ${SCRIPTS_DIR}"

# ---------------------------------------------------------------------------
# Python virtual environment
# ---------------------------------------------------------------------------
VENV_DIR="${SCRIPTS_DIR}/venv"
if [[ ! -d "${VENV_DIR}" ]]; then
  info "Creating Python virtual environment …"
  python3 -m venv "${VENV_DIR}"
fi

info "Installing Python dependencies …"
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet -r "${SCRIPTS_DIR}/requirements.txt"
ok "Dependencies installed"

# ---------------------------------------------------------------------------
# Prompt for credentials (or read from env vars in non-interactive mode)
# ---------------------------------------------------------------------------
_read_value() {
  local var_name="$1" prompt="$2" current="${!1:-}"
  if [[ -n "${current}" ]]; then
    echo "${current}"
    return
  fi
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    die "Required env var ${var_name} not set for non-interactive install"
  fi
  IFS= read -r -p "${prompt}: " value </dev/tty
  echo "${value}"
}

_read_secret() {
  local var_name="$1" prompt="$2" current="${!1:-}"
  if [[ -n "${current}" ]]; then
    echo "${current}"
    return
  fi
  if [[ "${NON_INTERACTIVE}" == "true" ]]; then
    die "Required env var ${var_name} not set for non-interactive install"
  fi
  IFS= read -r -s -p "${prompt}: " value </dev/tty; echo >/dev/tty
  echo "${value}"
}

ENV_FILE="${SCRIPTS_DIR}/.env"

if [[ -f "${ENV_FILE}" && "${OVERWRITE_ENV}" == "false" ]]; then
  warn ".env already exists at ${ENV_FILE} — skipping (use --overwrite-env to replace)"
else
  echo ""
  info "Configuring credentials …"

  BT_URL_VAL=$(       _read_value  "BT_URL"           "BeyondTrust PM Cloud URL (e.g. https://company.pm.beyondtrustcloud.com)")
  BT_CLIENT_ID_VAL=$( _read_value  "BT_CLIENT_ID"     "BeyondTrust OAuth2 Client ID")
  BT_SECRET_VAL=$(    _read_secret "BT_CLIENT_SECRET"  "BeyondTrust OAuth2 Client Secret")
  VEZA_URL_VAL=$(     _read_value  "VEZA_URL"          "Veza tenant URL (e.g. https://company.veza.com)")
  VEZA_KEY_VAL=$(     _read_secret "VEZA_API_KEY"      "Veza API Key")

  cat > "${ENV_FILE}" <<EOF
# BeyondTrust EPM → Veza OAA — generated by installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Protect this file: chmod 600 ${ENV_FILE}

# BeyondTrust PM Cloud
BT_URL=${BT_URL_VAL}
BT_CLIENT_ID=${BT_CLIENT_ID_VAL}
BT_CLIENT_SECRET=${BT_SECRET_VAL}

# Veza
VEZA_URL=${VEZA_URL_VAL}
VEZA_API_KEY=${VEZA_KEY_VAL}

# Optional overrides
# PROVIDER_NAME=BeyondTrust EPM
# DATASOURCE_NAME=BeyondTrust PM Cloud
EOF

  chmod 600 "${ENV_FILE}"
  ok ".env written to ${ENV_FILE} (permissions: 600)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  BeyondTrust EPM → Veza OAA — Installation Complete"
echo "================================================================"
echo "  Install dir : ${INSTALL_DIR}"
echo "  Scripts     : ${SCRIPTS_DIR}"
echo "  Logs        : ${LOGS_DIR}"
echo "  .env        : ${ENV_FILE}"
echo ""
echo "  Next steps:"
echo ""
echo "  1. Verify configuration:"
echo "     cat ${ENV_FILE}"
echo ""
echo "  2. Run a dry-run to validate:"
echo "     cd ${SCRIPTS_DIR}"
echo "     ./venv/bin/python3 ${SCRIPT_NAME} --env-file .env --dry-run --save-json"
echo ""
echo "  3. Push to Veza:"
echo "     ./venv/bin/python3 ${SCRIPT_NAME} --env-file .env"
echo ""
echo "  4. Schedule with cron (example — daily at 2 AM):"
echo "     0 2 * * * cd ${SCRIPTS_DIR} && ./venv/bin/python3 ${SCRIPT_NAME} --env-file .env >> ${LOGS_DIR}/cron.log 2>&1"
echo "================================================================"
