#!/usr/bin/env bash
# Generate the participant's PostgreSQL manifest from scenarios/templates/cluster.yaml.tpl.
# Usage: ./setup/init-workshop.sh [--force]
# The active project must be workshop-developerNN; the cluster is named pg-developerNN.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

TEMPLATE="${REPO_ROOT}/scenarios/templates/cluster.yaml.tpl"
OUTPUT="${REPO_ROOT}/scenarios/manifests/cluster.yaml"

FORCE=0
case "${1:-}" in
  "") ;;
  --force) FORCE=1 ;;
  *) echo "Usage: $(basename "$0") [--force]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $(basename "$0") [--force]" >&2; exit 2; }

have oc || die "oc not found in PATH"
have envsubst || die "envsubst not found (package gettext)"
[[ -f "${TEMPLATE}" ]] || die "template not found: ${TEMPLATE}"

NAMESPACE="$(oc project -q 2>/dev/null)" || die "cannot read the active project (run 'oc login' first)"
[[ "${NAMESPACE}" =~ ^workshop-developer[0-9]{2}$ ]] \
  || die "active project '${NAMESPACE}' does not match workshop-developerNN (use 'oc project workshop-developerNN')"
CLUSTER_NAME="pg-${NAMESPACE#workshop-}"
export NAMESPACE CLUSTER_NAME

if [[ -e "${OUTPUT}" && "${FORCE}" -ne 1 ]]; then
  log_info "Manifest already exists: ${OUTPUT} (use --force to regenerate)"
  exit 0
fi

mkdir -p "$(dirname "${OUTPUT}")" || die "cannot create $(dirname "${OUTPUT}")"
TMP="${OUTPUT}.tmp.$$"
trap 'rm -f "${TMP}"' EXIT
envsubst '${CLUSTER_NAME} ${NAMESPACE}' < "${TEMPLATE}" > "${TMP}" || die "manifest generation failed"
[[ -s "${TMP}" ]] || die "manifest generation produced an empty file"
mv "${TMP}" "${OUTPUT}" || die "cannot write ${OUTPUT}"
log_success "Manifest generated: ${OUTPUT} (cluster ${CLUSTER_NAME}, project ${NAMESPACE})"
