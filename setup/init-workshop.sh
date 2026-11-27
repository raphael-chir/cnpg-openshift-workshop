#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup/init-workshop.sh
# Generate the participant's PostgreSQL manifest from scenarios/templates/cluster.yaml.tpl.
# The user must be <USER_PREFIX>NN: the target project is <PROJECT_PREFIX>-<user>, the cluster <CLUSTER_PREFIX>-<user>
# (setup/workshop.env). The active OpenShift project is never used nor changed.
# Prerequisites: oc logged in as the participant, envsubst (package gettext).
# Usage: ./setup/init-workshop.sh [--force]
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=workshop.env
source "${SCRIPT_DIR}/workshop.env"

TEMPLATE="${REPO_ROOT}/scenarios/templates/cluster.yaml.tpl"
OUTPUT="${REPO_ROOT}/scenarios/manifests/cluster.yaml"

# Sets USER_NAME, NAMESPACE and CLUSTER_NAME, after checking that the participant can use the project.
resolve_target() {
  USER_NAME="$(oc whoami 2>/dev/null)" || die "cannot read the current user (run 'oc login' first)"
  [[ "${USER_NAME}" =~ ^${USER_PREFIX}[0-9]{2}$ ]] || die "user '${USER_NAME}' does not match ${USER_PREFIX}NN"
  NAMESPACE="${PROJECT_PREFIX}-${USER_NAME}"
  CLUSTER_NAME="${CLUSTER_PREFIX}-${USER_NAME}"
  export NAMESPACE CLUSTER_NAME

  # "oc get project" works for a project admin; "get namespace" is cluster-scoped and is not required.
  oc get project "${NAMESPACE}" >/dev/null 2>&1 || die "project ${NAMESPACE} not found or not accessible for ${USER_NAME}"
  [[ "$(oc auth can-i create clusters.postgresql.k8s.enterprisedb.io -n "${NAMESPACE}" 2>/dev/null || true)" == "yes" ]] \
    || die "${USER_NAME} cannot create EDB PostgreSQL Cluster resources in ${NAMESPACE}"
}

generate_manifest() {
  TMP="${OUTPUT}.tmp.$$"   # global: the EXIT trap runs after this function returns
  mkdir -p "$(dirname "${OUTPUT}")" || die "cannot create $(dirname "${OUTPUT}")"
  trap 'rm -f "${TMP}"' EXIT
  envsubst '${CLUSTER_NAME} ${NAMESPACE}' < "${TEMPLATE}" > "${TMP}" || die "manifest generation failed"
  [[ -s "${TMP}" ]] || die "manifest generation produced an empty file"
  mv "${TMP}" "${OUTPUT}" || die "cannot write ${OUTPUT}"
  log_success "Manifest generated: ${OUTPUT} (cluster ${CLUSTER_NAME}, project ${NAMESPACE})"
}

main() {
  local force=0
  case "$#:${1:-}" in
    0:) ;;
    1:--force) force=1 ;;
    *) echo "Usage: $(basename "$0") [--force]" >&2; exit 2 ;;
  esac

  have oc || die "oc not found in PATH"
  have envsubst || die "envsubst not found (package gettext)"
  [[ -f "${TEMPLATE}" ]] || die "template not found: ${TEMPLATE}"

  resolve_target

  if [[ -e "${OUTPUT}" && "${force}" -ne 1 ]]; then
    grep -qx "  namespace: ${NAMESPACE}" "${OUTPUT}" \
      || die "existing manifest ${OUTPUT} does not target ${NAMESPACE}: run with --force to regenerate"
    log_info "Manifest already exists for ${NAMESPACE}: ${OUTPUT} (use --force to regenerate)"
    return 0
  fi
  generate_manifest
}

main "$@"
