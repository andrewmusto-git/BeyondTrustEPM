#!/usr/bin/env bash
# preflight_beyondtrust_epm.sh — Pre-deployment validation for BeyondTrust EPM → Veza OAA
#
# Usage:
#   bash preflight_beyondtrust_epm.sh --all          # run all checks, exit 0/1
#   bash preflight_beyondtrust_epm.sh                # interactive menu
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/beyondtrust_epm.py"
ENV_FILE="${SCRIPT_DIR}/.env"
LOG_FILE="${SCRIPT_DIR}/preflight_$(date +%Y%m%d_%H%M%S).log"
MIN_PYTHON_MAJOR=3
MIN_PYTHON_MINOR=9

# Colour codes
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNING=0

pass()  { echo -e "${GREEN}✓${NC}  $*"; echo "[PASS]  $*" >> "${LOG_FILE}"; (( TESTS_PASSED++ )); }
fail()  { echo -e "${RED}✗${NC}  $*"; echo "[FAIL]  $*" >> "${LOG_FILE}"; (( TESTS_FAILED++ )); }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; echo "[WARN]  $*" >> "${LOG_FILE}"; (( TESTS_WARNING++ )); }
info()  { echo -e "${BLUE}ℹ${NC}  $*"; echo "[INFO]  $*" >> "${LOG_FILE}"; }
header(){ echo ""; echo -e "${BLUE}── $* ──${NC}"; echo "" >> "${LOG_FILE}"; echo "── $* ──" >> "${LOG_FILE}"; }

_mask() {
  local val="$1"
  local len="${#val}"
  if (( len <= 4 )); then echo "****"; else echo "${val:0:2}****${val: -2}"; fi
}

# ---------------------------------------------------------------------------
# Resolve python binary (prefer venv)
# ---------------------------------------------------------------------------
PYTHON_BIN="python3"
if [[ -f "${SCRIPT_DIR}/venv/bin/python3" ]]; then
  PYTHON_BIN="${SCRIPT_DIR}/venv/bin/python3"
fi

# ---------------------------------------------------------------------------
# 1. System Requirements
# ---------------------------------------------------------------------------
check_system() {
  header "1. System Requirements"

  # Python version
  if command -v "${PYTHON_BIN}" &>/dev/null; then
    PY_VER=$("${PYTHON_BIN}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}')")
    PY_MAJOR=$("${PYTHON_BIN}" -c "import sys; print(sys.version_info.major)")
    PY_MINOR=$("${PYTHON_BIN}" -c "import sys; print(sys.version_info.minor)")
    if (( PY_MAJOR < MIN_PYTHON_MAJOR || (PY_MAJOR == MIN_PYTHON_MAJOR && PY_MINOR < MIN_PYTHON_MINOR) )); then
      fail "Python ${MIN_PYTHON_MAJOR}.${MIN_PYTHON_MINOR}+ required — found ${PY_VER} at ${PYTHON_BIN}"
    else
      pass "Python ${PY_VER} (${PYTHON_BIN})"
    fi
  else
    fail "python3 not found"
  fi

  # pip
  if "${PYTHON_BIN}" -m pip --version &>/dev/null 2>&1; then
    pass "pip available"
  else
    fail "pip not found for ${PYTHON_BIN}"
  fi

  # curl
  if command -v curl &>/dev/null; then
    pass "curl $(curl --version | head -1 | awk '{print $2}')"
  else
    warn "curl not found — network checks will be limited"
  fi

  # jq (optional)
  if command -v jq &>/dev/null; then
    pass "jq $(jq --version)"
  else
    warn "jq not found (optional — useful for inspecting JSON payloads)"
  fi
}

# ---------------------------------------------------------------------------
# 2. Python Dependencies
# ---------------------------------------------------------------------------
check_python_deps() {
  header "2. Python Dependencies"

  local req_file="${SCRIPT_DIR}/requirements.txt"
  if [[ ! -f "${req_file}" ]]; then
    fail "requirements.txt not found at ${req_file}"
    return
  fi

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
    # Strip version specifier to get package name
    pkg=$(echo "${line}" | sed 's/[>=<!\[].*//' | tr -d ' ')
    [[ -z "${pkg}" ]] && continue
    if "${PYTHON_BIN}" -c "import importlib; importlib.import_module('${pkg//-/_}')" 2>/dev/null; then
      ver=$("${PYTHON_BIN}" -c "import importlib.metadata; print(importlib.metadata.version('${pkg}'))" 2>/dev/null || echo "unknown")
      pass "${pkg} (${ver})"
    else
      fail "${pkg} — NOT importable (run: ${PYTHON_BIN} -m pip install -r ${req_file})"
    fi
  done < "${req_file}"
}

# ---------------------------------------------------------------------------
# 3. Configuration / .env
# ---------------------------------------------------------------------------
check_config() {
  header "3. Configuration"

  if [[ ! -f "${ENV_FILE}" ]]; then
    fail ".env not found at ${ENV_FILE} — copy .env.example and populate"
    return
  fi
  pass ".env file exists at ${ENV_FILE}"

  # Permissions
  local perms
  perms=$(stat -c "%a" "${ENV_FILE}" 2>/dev/null || stat -f "%OLp" "${ENV_FILE}" 2>/dev/null || echo "unknown")
  if [[ "${perms}" == "600" ]]; then
    pass ".env permissions: 600"
  else
    warn ".env permissions: ${perms} (recommend: chmod 600 ${ENV_FILE})"
  fi

  # Load vars
  # shellcheck disable=SC1090
  set -a; source "${ENV_FILE}" 2>/dev/null; set +a

  REQUIRED_VARS=("BT_URL" "BT_CLIENT_ID" "BT_CLIENT_SECRET" "VEZA_URL" "VEZA_API_KEY")
  for var in "${REQUIRED_VARS[@]}"; do
    val="${!var:-}"
    if [[ -z "${val}" ]]; then
      fail "${var} is not set"
    elif [[ "${val}" == your_* || "${val}" == *_here ]]; then
      fail "${var} still has placeholder value — update ${ENV_FILE}"
    else
      # Mask secrets
      if [[ "${var}" =~ PASSWORD|KEY|TOKEN|SECRET ]]; then
        pass "${var} = $(_mask "${val}")"
      else
        pass "${var} = ${val}"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# 4. Network Connectivity
# ---------------------------------------------------------------------------
check_network() {
  header "4. Network Connectivity"

  # Reload .env if not already loaded
  if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a
  fi

  local bt_url="${BT_URL:-}"
  local veza_url="${VEZA_URL:-}"

  if [[ -n "${bt_url}" ]]; then
    local bt_host
    bt_host=$(echo "${bt_url}" | sed 's|https\?://||' | cut -d/ -f1)
    if command -v curl &>/dev/null; then
      local start end latency http_code
      start=$(date +%s%3N 2>/dev/null || echo 0)
      http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "${bt_url}/" 2>/dev/null || echo "000")
      end=$(date +%s%3N 2>/dev/null || echo 0)
      latency=$(( end - start ))
      if [[ "${http_code}" != "000" ]]; then
        pass "BeyondTrust PM Cloud (${bt_host}) — HTTP ${http_code} — ${latency}ms"
      else
        fail "Cannot reach BeyondTrust PM Cloud at ${bt_url} (timeout/DNS)"
      fi
    else
      warn "curl not available — skipping BeyondTrust connectivity check"
    fi
  else
    warn "BT_URL not set — skipping BeyondTrust connectivity check"
  fi

  if [[ -n "${veza_url}" ]]; then
    local veza_host
    veza_host=$(echo "${veza_url}" | sed 's|https\?://||' | cut -d/ -f1)
    if command -v curl &>/dev/null; then
      local http_code
      http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 10 "${veza_url}/" 2>/dev/null || echo "000")
      if [[ "${http_code}" != "000" ]]; then
        pass "Veza (${veza_host}) — HTTP ${http_code}"
      else
        fail "Cannot reach Veza at ${veza_url}"
      fi
    else
      warn "curl not available — skipping Veza connectivity check"
    fi
  else
    warn "VEZA_URL not set — skipping Veza connectivity check"
  fi
}

# ---------------------------------------------------------------------------
# 5. API Authentication
# ---------------------------------------------------------------------------
check_auth() {
  header "5. API Authentication"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a
  fi

  local bt_url="${BT_URL:-}"
  local bt_client_id="${BT_CLIENT_ID:-}"
  local bt_client_secret="${BT_CLIENT_SECRET:-}"
  local veza_url="${VEZA_URL:-}"
  local veza_api_key="${VEZA_API_KEY:-}"

  # BeyondTrust OAuth2 token test
  if [[ -n "${bt_url}" && -n "${bt_client_id}" && -n "${bt_client_secret}" ]] && command -v curl &>/dev/null; then
    local token_url="${bt_url}/oauth/connect/token"
    local http_code response
    response=$(curl -s -w "\n%{http_code}" --max-time 15 -X POST "${token_url}" \
      --data-urlencode "grant_type=client_credentials" \
      --data-urlencode "client_id=${bt_client_id}" \
      --data-urlencode "client_secret=${bt_client_secret}" \
      --data-urlencode "scope=urn:management:api" 2>/dev/null || echo -e "\n000")
    http_code=$(echo "${response}" | tail -1)
    if [[ "${http_code}" == "200" ]]; then
      pass "BeyondTrust OAuth2 token obtained (HTTP 200)"
    else
      body=$(echo "${response}" | head -1 | cut -c1-200)
      fail "BeyondTrust OAuth2 token request failed: HTTP ${http_code} — ${body}"
    fi
  else
    warn "Skipping BeyondTrust auth test — missing BT_URL, BT_CLIENT_ID, or BT_CLIENT_SECRET"
  fi

  # Veza API key test
  if [[ -n "${veza_url}" && -n "${veza_api_key}" ]] && command -v curl &>/dev/null; then
    local http_code
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
      -H "Authorization: Bearer ${veza_api_key}" \
      "${veza_url}/api/v1/providers" 2>/dev/null || echo "000")
    if [[ "${http_code}" == "200" ]]; then
      pass "Veza API key valid (GET /api/v1/providers HTTP 200)"
    elif [[ "${http_code}" == "401" || "${http_code}" == "403" ]]; then
      fail "Veza API key rejected (HTTP ${http_code}) — verify VEZA_API_KEY"
    else
      warn "Veza API key check returned HTTP ${http_code} — may still work"
    fi
  else
    warn "Skipping Veza auth test — missing VEZA_URL or VEZA_API_KEY"
  fi
}

# ---------------------------------------------------------------------------
# 6. Veza Endpoint Access (Query API)
# ---------------------------------------------------------------------------
check_veza_access() {
  header "6. Veza Endpoint Access"

  if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a
  fi

  local veza_url="${VEZA_URL:-}"
  local veza_api_key="${VEZA_API_KEY:-}"

  if [[ -n "${veza_url}" && -n "${veza_api_key}" ]] && command -v curl &>/dev/null; then
    local http_code
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 15 \
      -H "Authorization: Bearer ${veza_api_key}" \
      -H "Content-Type: application/json" \
      -X POST "${veza_url}/api/v1/query" \
      --data '{"query":{"node_types":["User"],"properties":[{"name":"id"}],"limit":1}}' \
      2>/dev/null || echo "000")
    if [[ "${http_code}" == "200" || "${http_code}" == "201" ]]; then
      pass "Veza Query API accessible (HTTP ${http_code})"
    else
      warn "Veza Query API returned HTTP ${http_code} — push may still work"
    fi
  else
    warn "Skipping Veza Query API check — missing VEZA_URL or VEZA_API_KEY"
  fi
}

# ---------------------------------------------------------------------------
# 7. Deployment Structure
# ---------------------------------------------------------------------------
check_structure() {
  header "7. Deployment Structure"

  # Main script
  if [[ -f "${PYTHON_SCRIPT}" && -r "${PYTHON_SCRIPT}" ]]; then
    pass "Main script found: ${PYTHON_SCRIPT}"
  else
    fail "Main script not found or not readable: ${PYTHON_SCRIPT}"
  fi

  # Validate --help works
  if "${PYTHON_BIN}" "${PYTHON_SCRIPT}" --help &>/dev/null 2>&1; then
    pass "Script --help executes without errors"
  else
    fail "Script --help failed — check Python syntax and imports"
  fi

  # Logs directory
  local logs_dir="${SCRIPT_DIR}/logs"
  if [[ -d "${logs_dir}" ]]; then
    if [[ -w "${logs_dir}" ]]; then
      pass "Logs directory writable: ${logs_dir}"
    else
      warn "Logs directory not writable: ${logs_dir} (run: chmod 755 ${logs_dir})"
    fi
  else
    warn "Logs directory does not exist yet (will be created on first run): ${logs_dir}"
  fi

  # Running user
  pass "Running as: $(whoami)"

  # .env.example
  if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
    pass ".env.example present"
  else
    warn ".env.example not found"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  echo ""
  echo "================================================================"
  echo "  Preflight Summary"
  echo "================================================================"
  echo -e "  ${GREEN}Passed:${NC}   ${TESTS_PASSED}"
  echo -e "  ${YELLOW}Warnings:${NC} ${TESTS_WARNING}"
  echo -e "  ${RED}Failed:${NC}   ${TESTS_FAILED}"
  echo "  Log:      ${LOG_FILE}"
  echo "================================================================"
  echo ""

  {
    echo ""
    echo "=== SUMMARY ==="
    echo "Passed:   ${TESTS_PASSED}"
    echo "Warnings: ${TESTS_WARNING}"
    echo "Failed:   ${TESTS_FAILED}"
  } >> "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
interactive_menu() {
  while true; do
    echo ""
    echo "================================================================"
    echo "  BeyondTrust EPM → Veza OAA — Preflight Checks"
    echo "================================================================"
    echo "  1) System Requirements"
    echo "  2) Python Dependencies"
    echo "  3) Configuration (.env)"
    echo "  4) Network Connectivity"
    echo "  5) API Authentication"
    echo "  6) Veza Endpoint Access"
    echo "  7) Deployment Structure"
    echo "  8) Run ALL checks"
    echo "  9) Show current config (masked)"
    echo " 10) Generate .env template"
    echo " 11) Install dependencies"
    echo "  q) Quit"
    echo "================================================================"
    IFS= read -r -p "Choose an option: " choice </dev/tty
    case "${choice}" in
      1)  check_system ;;
      2)  check_python_deps ;;
      3)  check_config ;;
      4)  check_network ;;
      5)  check_auth ;;
      6)  check_veza_access ;;
      7)  check_structure ;;
      8)  run_all; print_summary ;;
      9)  show_config ;;
      10) gen_env_template ;;
      11) "${PYTHON_BIN}" -m pip install -r "${SCRIPT_DIR}/requirements.txt" && ok "Dependencies installed" ;;
      q|Q) exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
  done
}

show_config() {
  header "Current Configuration (masked)"
  if [[ -f "${ENV_FILE}" ]]; then
    set -a; source "${ENV_FILE}" 2>/dev/null; set +a
    for var in BT_URL BT_CLIENT_ID BT_CLIENT_SECRET VEZA_URL VEZA_API_KEY; do
      val="${!var:-<not set>}"
      if [[ "${var}" =~ SECRET|KEY|PASSWORD|TOKEN ]]; then
        echo "  ${var} = $(_mask "${val}")"
      else
        echo "  ${var} = ${val}"
      fi
    done
  else
    warn ".env not found at ${ENV_FILE}"
  fi
}

gen_env_template() {
  local out="${SCRIPT_DIR}/.env.new"
  cp -n "${SCRIPT_DIR}/.env.example" "${out}" 2>/dev/null \
    || warn ".env.example not found — cannot generate template"
  ok "Template written to ${out}"
}

run_all() {
  TESTS_PASSED=0; TESTS_FAILED=0; TESTS_WARNING=0
  check_system
  check_python_deps
  check_config
  check_network
  check_auth
  check_veza_access
  check_structure
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "BeyondTrust EPM → Veza OAA — Preflight Validation" | tee -a "${LOG_FILE}"
echo "Started: $(date -u)" | tee -a "${LOG_FILE}"
echo "" | tee -a "${LOG_FILE}"

if [[ "${1:-}" == "--all" ]]; then
  run_all
  print_summary
  [[ ${TESTS_FAILED} -eq 0 ]] && exit 0 || exit 1
else
  interactive_menu
fi
