#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 07
# PostgreSQL Minor & Major Upgrades
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

USER_NAME="$(oc whoami)"
NAMESPACE="workshop-${USER_NAME}"
CLUSTER_NAME="pg-${USER_NAME}"

MINOR_IMAGE="docker.enterprisedb.com/k8s/postgresql:17.7"
MAJOR_IMAGE="docker.enterprisedb.com/k8s/postgresql:18"

show_instruct() {
  ui_note "
# 07 / PostgreSQL Upgrades

Upgrade PostgreSQL using EDB CloudNativePG.

## Objectives
- Perform a minor upgrade to PostgreSQL 17.7
- Observe the rolling update of PostgreSQL instances
- Perform an in-place major upgrade from PostgreSQL 17 to 18
- Observe the upgrade job and PostgreSQL recovery

## Expected outcome
PostgreSQL 18 is running on the existing cluster.

## Important
The major upgrade requires downtime.
All PostgreSQL instances stop while pg_upgrade runs.
A valid backup should be available before proceeding.
"
  ui_pause
}

play() {
  ui_info "Current PostgreSQL version"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c \"SHOW server_version;\""
  ui_pause

  ui_info "Minor upgrade: PostgreSQL 17 to 17.7"
  ui_command "oc patch cluster ${CLUSTER_NAME} --type merge -p '{\"spec\":{\"imageName\":\"${MINOR_IMAGE}\"}}'"
  ui_pause

  ui_info "Observe PostgreSQL rolling update"
  ui_watch "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole"
  ui_pause

  ui_info "Verify PostgreSQL version"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c \"SHOW server_version;\""
  ui_pause

  ui_warn "Major upgrade to PostgreSQL 18: all instances will stop and PostgreSQL will be unavailable."
  ui_confirm "Upgrade PostgreSQL 17 to 18 in place?" || return 0

  ui_info "Major upgrade: PostgreSQL 17 to 18"
  ui_command "oc patch cluster ${CLUSTER_NAME} --type merge -p '{\"spec\":{\"imageName\":\"${MAJOR_IMAGE}\"}}'"
  ui_pause

  ui_info "Observe PostgreSQL upgrade and recovery"
  ui_watch "oc get pods,jobs -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME}"
  ui_pause

  ui_info "Verify PostgreSQL 18"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c \"SELECT version();\""
  ui_pause

  ui_info "Verify cluster health"
  ui_command "oc cnp status ${CLUSTER_NAME}"
  ui_pause

  ui_success "PostgreSQL upgrade scenario completed."
  ui_info "Next scenario: 08"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
