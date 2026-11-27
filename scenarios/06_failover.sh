#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 06
# Automatic failover: primary storage failure
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

USER_NAME="$(oc whoami)"
NAMESPACE="workshop-${USER_NAME}"
CLUSTER_NAME="pg-${USER_NAME}"

show_instruct() {
  ui_note "
# 06 / Automatic Failover

## Objectives
- Identify the current PostgreSQL primary
- Simulate permanent loss of its Pod and storage
- Observe automatic failover
- Verify cluster recovery

## Expected outcome
A replica becomes the new primary and the cluster recovers.
"
  ui_pause
}

play() {
  local primary
  primary=$(oc get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.currentPrimary}')
  [[ -n "$primary" ]] || { ui_error "No primary found"; return 1; }

  ui_info "Identify the current PostgreSQL primary"
  ui_command "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole -o wide"
  ui_pause

  ui_warn "Simulate permanent storage failure of primary ${primary}."
  ui_confirm "Delete primary Pod and its PVCs?" || return 0

  local pvc_list
  pvc_list=$(oc get pvc "${primary}" "${primary}-wal" \
    --ignore-not-found -o name | tr '\n' ' ')

  ui_info "Delete primary Pod and available PVCs"
  ui_command "oc delete pod/${primary} ${pvc_list} --force --grace-period=0"
  ui_pause

  ui_info "Observe automatic failover and primary election"
  ui_watch "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole"
  ui_pause

  ui_info "Verify the new PostgreSQL primary"
  local new_primary
  new_primary=$(oc get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.currentPrimary}')

  if [[ -n "$new_primary" && "$new_primary" != "$primary" ]]; then
    ui_success "Automatic failover completed: ${primary} -> ${new_primary}"
  else
    ui_warn "Primary has not changed yet. Check cluster status."
  fi

  ui_info "Verify PostgreSQL cluster recovery"
  ui_command "oc cnp status ${CLUSTER_NAME}"
  ui_pause

  ui_success "Automatic failover scenario completed."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
