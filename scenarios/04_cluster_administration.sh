#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 04
# Cluster administration: scaling and hibernation
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
# 04 / Cluster Administration

## Objectives
- Scale PostgreSQL from 3 to 2 instances and back
- Hibernate and resume the cluster

## Expected outcome
A healthy PostgreSQL cluster with 3 running instances.
"
  ui_pause
}

play() {
  ui_info "Explore EDB CNPG administration commands"
  ui_command "oc cnp --help"
  ui_pause

  ui_info "Scale down PostgreSQL to 2 instances"
  ui_command "oc scale cluster ${CLUSTER_NAME} --replicas=2"
  ui_pause
  ui_watch "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole"

  ui_info "Scale up PostgreSQL to 3 instances"
  ui_command "oc scale cluster ${CLUSTER_NAME} --replicas=3"
  ui_pause
  ui_watch "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole"

  ui_info "Hibernate PostgreSQL cluster"
  ui_command "oc cnp hibernate on ${CLUSTER_NAME}"
  ui_pause
  ui_watch "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole"

  ui_info "Resume PostgreSQL cluster"
  ui_command "oc cnp hibernate off ${CLUSTER_NAME}"
  ui_pause
  ui_watch "oc get pods -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME} -L k8s.enterprisedb.io/instanceRole"

  ui_success "Cluster administration scenario completed."
  ui_info "Next scenario: 05_high_availability.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
