#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup/init-workshop.sh
# Generate all participant manifests from scenarios/templates/*.yaml.tpl.
# Existing manifests are preserved unless --force is specified.
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/logger.sh"
source "${REPO_ROOT}/lib/common.sh"
source "${SCRIPT_DIR}/workshop.env"

TEMPLATE_DIR="${REPO_ROOT}/scenarios/templates"
OUTPUT_DIR="${REPO_ROOT}/scenarios/manifests"

resolve_target() {
  USER_NAME="$(oc whoami 2>/dev/null)" || die "cannot read current user (run 'oc login' first)"

  [[ "${USER_NAME}" =~ ^${USER_PREFIX}[0-9]{2}$ ]] \
    || die "user '${USER_NAME}' does not match ${USER_PREFIX}NN"

  NAMESPACE="${PROJECT_PREFIX}-${USER_NAME}"
  CLUSTER_NAME="${CLUSTER_PREFIX}-${USER_NAME}"
  export NAMESPACE CLUSTER_NAME

  oc get project "${NAMESPACE}" >/dev/null 2>&1 \
    || die "project ${NAMESPACE} not found or not accessible"

  [[ "$(oc auth can-i create clusters.postgresql.k8s.enterprisedb.io -n "${NAMESPACE}" 2>/dev/null || true)" == "yes" ]] \
    || die "${USER_NAME} cannot create EDB PostgreSQL Cluster resources"
}

generate_manifests() {
  local template output name tmp
  local generated=0 skipped=0

  mkdir -p "${OUTPUT_DIR}" || die "cannot create ${OUTPUT_DIR}"

  for template in "${TEMPLATE_DIR}"/*.yaml.tpl; do
    [[ -f "${template}" ]] || continue

    name="$(basename "${template}" .yaml.tpl)"
    output="${OUTPUT_DIR}/${name}.yaml"

    if [[ -e "${output}" && "${FORCE}" -ne 1 ]]; then
      grep -Eq "^[[:space:]]*namespace:[[:space:]]*${NAMESPACE}[[:space:]]*$" "${output}" \
        || die "existing manifest ${output} does not target ${NAMESPACE}: use --force"

      log_info "Manifest already exists: ${output}"
      skipped=$((skipped + 1))
      continue
    fi

    tmp="$(mktemp "${OUTPUT_DIR}/.${name}.XXXXXX")" \
      || die "cannot create temporary manifest"

    envsubst '${CLUSTER_NAME} ${NAMESPACE}' < "${template}" > "${tmp}" \
      || { rm -f "${tmp}"; die "failed to generate ${output}"; }

    [[ -s "${tmp}" ]] \
      || { rm -f "${tmp}"; die "generated manifest is empty: ${output}"; }

    mv "${tmp}" "${output}" \
      || { rm -f "${tmp}"; die "cannot write ${output}"; }

    log_success "Generated: ${output}"
    generated=$((generated + 1))
  done

  [[ $((generated + skipped)) -gt 0 ]] \
    || die "no *.yaml.tpl templates found in ${TEMPLATE_DIR}"

  log_success "Manifests: ${generated} generated, ${skipped} preserved"
}

main() {
  FORCE=0

  case "$#:${1:-}" in
    0:) ;;
    1:--force) FORCE=1 ;;
    *) echo "Usage: $(basename "$0") [--force]" >&2; exit 2 ;;
  esac

  have oc || die "oc not found in PATH"
  have envsubst || die "envsubst not found (package gettext)"

  [[ -d "${TEMPLATE_DIR}" ]] \
    || die "template directory not found: ${TEMPLATE_DIR}"

  resolve_target
  generate_manifests
}

main "$@"
