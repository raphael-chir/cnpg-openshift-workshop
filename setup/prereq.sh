#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup/prereq.sh
# Read-only prerequisite checker for the EDB CNPG OpenShift workshop: nothing is installed or modified.
# Prerequisites: oc, helm, cluster-admin access. With --crc: crc (OpenShift Local).
# Usage: ./setup/prereq.sh admin [--crc]
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

PASS=0; WARN=0; FAIL=0
CRC_MODE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") admin [--crc]

  admin        Check tooling and cluster-admin access for infrastructure preparation
  admin --crc  Same, for OpenShift Local: also checks crc is installed and running,
               and configures oc from 'crc oc-env' if oc is not in PATH

Read-only: nothing is installed or modified.
EOF
}

# One logger level per result: SUCCESS = pass, WARN = warning, ERROR = failure.
pass() { log_success "$*"; PASS=$((PASS + 1)); }
warn() { log_warn "$*"; WARN=$((WARN + 1)); }
fail() { log_error "$*"; FAIL=$((FAIL + 1)); }

summary() {
  log_info "Summary: ${PASS} PASS, ${WARN} WARN, ${FAIL} FAIL"
  [[ "${FAIL}" -eq 0 ]]
}

OC_OK=0      # oc present
AUTH_OK=0    # oc authenticated

check_oc() {
  if have oc; then pass "oc installed"; OC_OK=1; else fail "oc installed (not found in PATH)"; fi
}

check_auth() {
  if [[ "${OC_OK}" -ne 1 ]]; then
    fail "OpenShift connection (skipped: oc missing)"; return
  fi
  local user
  if user="$(oc whoami 2>/dev/null)" && [[ -n "${user}" ]]; then
    pass "OpenShift connection (user: ${user})"; AUTH_OK=1
  else
    fail "OpenShift connection (API unreachable or not logged in: run 'oc login')"
  fi
}

check_default_sc() {
  local out=""
  if [[ "${AUTH_OK}" -ne 1 ]]; then
    fail "Default StorageClass (skipped: not authenticated)"; return
  fi
  out="$(oc get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true)"
  out="${out%%$'\n'*}"
  if [[ -n "${out}" ]]; then pass "Default StorageClass: ${out}"
  else fail "Default StorageClass not found (or not readable)"; fi
}

check_crc() {
  local ok=0
  if have crc; then pass "crc installed"; ok=1; else fail "crc installed (not found in PATH)"; fi
  if [[ "${ok}" -ne 1 ]]; then fail "CRC running (skipped: crc missing)"
  elif crc_is_running; then pass "CRC running"
  else fail "CRC running (OpenShift not reported as Running by 'crc status'; start it yourself)"; fi
  if ! have oc; then
    if init_oc_from_crc; then pass "oc configured via crc oc-env"
    else fail "oc configured via crc oc-env (could not configure oc)"; fi
  fi
}

run_admin() {
  [[ "${CRC_MODE}" -eq 1 ]] && check_crc
  check_oc
  if have helm && [[ -x "$(command -v helm)" ]]; then pass "helm installed"
  else fail "helm installed (not found or not executable)"; fi
  check_auth

  if [[ "${AUTH_OK}" -eq 1 ]]; then
    if [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null || true)" == "yes" ]]; then
      pass "Cluster-admin privileges"
    else
      fail "Cluster-admin privileges (oc auth can-i '*' '*' --all-namespaces != yes)"
    fi
  else
    fail "Cluster-admin privileges (skipped: not authenticated)"
  fi

  check_default_sc
  if have envsubst; then pass "envsubst installed"
  else warn "envsubst not installed (part of gettext; on macOS: brew install gettext && brew link --force gettext)"; fi
}

main() {
  case "${1:-}:$#:${2:-}" in
    admin:1:) ;;
    admin:2:--crc) CRC_MODE=1 ;;
    *) usage >&2; exit 2 ;;
  esac
  log_section "EDB CNPG Workshop — Prerequisites (admin$([[ "${CRC_MODE}" -eq 1 ]] && echo ' --crc'))"
  run_admin
  summary
}

main "$@"
