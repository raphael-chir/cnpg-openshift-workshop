#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 05
# High availability: fencing and switchover
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
# 05 / High Availability

## Objectives
- Fence a replica without deleting its Pod
- Verify PostgreSQL process status
- Perform a controlled switchover

## Expected outcome
All instances are unfenced and a replica has become primary.
"
  ui_pause
}

play() {
  local replica
  replica=$(oc get pods -l "k8s.enterprisedb.io/cluster=${CLUSTER_NAME},k8s.enterprisedb.io/instanceRole=replica" -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$replica" ]] || { ui_error "No replica available for fencing"; return 1; }

  ui_info "Fence replica ${replica} without deleting its Pod"
  ui_command "oc cnp fencing on ${CLUSTER_NAME} ${replica}"
  ui_pause

  ui_info "Verify PostgreSQL is stopped"
  ui_command "oc exec ${replica} -c postgres -- pg_ctl status || true"
  ui_pause

  ui_info "Remove fencing from replica ${replica}"
  ui_command "oc cnp fencing off ${CLUSTER_NAME} ${replica}"
  ui_pause

  ui_info "Verify PostgreSQL is running again"
  ui_command "oc exec ${replica} -c postgres -- pg_ctl status"
  ui_pause

  ui_info "Identify the current PostgreSQL primary and replicas"
  ui_command "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole -o wide"
  ui_pause

  local promote_replica
  promote_replica=$(oc get pods -l "k8s.enterprisedb.io/cluster=${CLUSTER_NAME},k8s.enterprisedb.io/instanceRole=replica" -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$promote_replica" ]] || { ui_error "No replica available"; return 1; }

  ui_info "Perform a controlled switchover to ${promote_replica}"
  ui_command "oc cnp promote ${CLUSTER_NAME} ${promote_replica}"
  ui_pause

  ui_info "Observe PostgreSQL roles after switchover"
  ui_watch "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole"

  ui_info "Verify PostgreSQL cluster status"
  ui_command "oc cnp status ${CLUSTER_NAME}"
  ui_pause

  ui_success "High availability scenario completed."
  ui_info "Next scenario: 06_failover.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
