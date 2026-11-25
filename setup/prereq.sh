#!/usr/bin/env bash
# Read-only prerequisite checker for the EDB CNPG OpenShift workshop.
# Usage: ./setup/prereq.sh admin|participant
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

CNPG_GROUP="postgresql.k8s.enterprisedb.io"
CNPG_CRD="clusters.${CNPG_GROUP}"
MINIO_SECRET="minio-creds"
# Optional override of the EDB image pull secret name (no naming convention assumed).
EDB_PULL_SECRET_NAME="${EDB_PULL_SECRET_NAME:-}"

PASS=0; WARN=0; FAIL=0
CRC_MODE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") <admin [--crc]|participant>

  admin        Check tooling and cluster-admin access for infrastructure preparation
  admin --crc  Same, for OpenShift Local: also checks crc is installed and running,
               and configures oc from 'crc oc-env' if oc is not in PATH
  participant  Check tooling and namespace permissions for workshop scenarios

Read-only: nothing is installed or modified.
Optional env: EDB_PULL_SECRET_NAME (exact name of the EDB image pull secret)
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

# --- shared checks -----------------------------------------------------------
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

check_envsubst() { # $1 = fail|warn
  if have envsubst; then pass "envsubst installed"
  elif [[ "$1" == "fail" ]]; then fail "envsubst installed (not found; part of gettext; on macOS: brew install gettext && brew link --force gettext)"
  else warn "envsubst not installed (part of gettext; on macOS: brew install gettext && brew link --force gettext)"; fi
}

check_default_sc() { # $1 = fail|warn
  local sev="${1:-warn}" out=""
  if [[ "${AUTH_OK}" -ne 1 ]]; then
    "${sev}" "Default StorageClass (skipped: not authenticated)"; return
  fi
  out="$(oc get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true)"
  out="${out%%$'\n'*}"
  if [[ -n "${out}" ]]; then pass "Default StorageClass: ${out}"
  else "${sev}" "Default StorageClass not found (or not readable)"; fi
}

crd_exists() { oc get crd "${CNPG_CRD}" >/dev/null 2>&1; }

# --- admin -------------------------------------------------------------------
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

  check_default_sc fail
  check_envsubst warn
}

# --- participant ---------------------------------------------------------------
run_participant() {
  check_oc
  check_envsubst fail

  if have kubectl-cnp && [[ -x "$(command -v kubectl-cnp)" ]]; then
    if kubectl-cnp version --client >/dev/null 2>&1 || kubectl-cnp version >/dev/null 2>&1; then
      pass "kubectl-cnp available"
    else
      fail "kubectl-cnp available (found, but 'version' command failed)"
    fi
  else
    fail "kubectl-cnp available (not found or not executable; run ./setup/install-cnp-cli.sh)"
  fi

  check_auth

  local ns="" ns_ok=0
  if [[ "${AUTH_OK}" -eq 1 ]]; then
    if ns="$(oc project -q 2>/dev/null)" && [[ -n "${ns}" ]] \
       && oc get pods -n "${ns}" --request-timeout=15s >/dev/null 2>&1; then
      pass "Namespace: ${ns}"; ns_ok=1
    else
      fail "Namespace accessible (could not determine or access current project)"
    fi
  else
    fail "Namespace (skipped: not authenticated)"
  fi

  if [[ "${AUTH_OK}" -eq 1 ]]; then
    if crd_exists; then pass "EDB CNPG CRD"
    else fail "EDB CNPG CRD (${CNPG_CRD} not found or not readable)"; fi
  else
    fail "EDB CNPG CRD (skipped: not authenticated)"
  fi

  if [[ "${ns_ok}" -eq 1 ]]; then
    local missing=() v r
    local checks=(
      "create clusters.${CNPG_GROUP}" "get clusters.${CNPG_GROUP}"
      "list clusters.${CNPG_GROUP}" "patch clusters.${CNPG_GROUP}"
      "delete clusters.${CNPG_GROUP}"
      "create backups.${CNPG_GROUP}" "get backups.${CNPG_GROUP}"
      "list backups.${CNPG_GROUP}" "delete backups.${CNPG_GROUP}"
      "create poolers.${CNPG_GROUP}" "get poolers.${CNPG_GROUP}"
      "list poolers.${CNPG_GROUP}" "delete poolers.${CNPG_GROUP}"
      "create pods/exec" "create pods/portforward"
    )
    for r in "${checks[@]}"; do
      v="${r%% *}"; local res="${r#* }"
      if [[ "$(oc auth can-i "${v}" "${res}" -n "${ns}" 2>/dev/null || true)" != "yes" ]]; then
        missing+=("${v} ${res}")
      fi
    done
    if [[ "${#missing[@]}" -eq 0 ]]; then
      pass "CNPG cluster permissions"
    else
      fail "CNPG cluster permissions (missing in ${ns}: $(IFS=,; echo "${missing[*]}"))"
    fi

    if oc get secret "${MINIO_SECRET}" -n "${ns}" >/dev/null 2>&1; then
      pass "MinIO credentials"
    else
      fail "MinIO credentials (secret '${MINIO_SECRET}' not found in ${ns})"
    fi

    local pull=""
    if [[ -n "${EDB_PULL_SECRET_NAME}" ]]; then
      oc get secret "${EDB_PULL_SECRET_NAME}" -n "${ns}" >/dev/null 2>&1 && pull="${EDB_PULL_SECRET_NAME}"
    else
      pull="$(oc get secrets -n "${ns}" --field-selector type=kubernetes.io/dockerconfigjson \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -i 'edb' | head -n1 || true)"
    fi
    if [[ -n "${pull}" ]]; then pass "EDB image pull secret (${pull})"
    else fail "EDB image pull secret (no dockerconfigjson secret matching 'edb' in ${ns}; set EDB_PULL_SECRET_NAME to override)"; fi
  else
    fail "CNPG cluster permissions (skipped: namespace unavailable)"
    fail "MinIO credentials (skipped: namespace unavailable)"
    fail "EDB image pull secret (skipped: namespace unavailable)"
  fi

  check_default_sc warn
  if have watch; then pass "watch available"; else warn "watch not installed (optional; on macOS: brew install watch)"; fi
}

# --- main ----------------------------------------------------------------------
main() {
  local mode="${1:-}"
  case "${mode}:$#:${2:-}" in
    admin:1:|participant:1:) ;;
    admin:2:--crc) CRC_MODE=1 ;;
    *) usage >&2; exit 2 ;;
  esac
  log_section "EDB CNPG Workshop — Prerequisites (${mode}$([[ "${CRC_MODE}" -eq 1 ]] && echo ' --crc'))"
  "run_${mode}"
  summary
}

main "$@"
