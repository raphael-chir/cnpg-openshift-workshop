#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 09
# PostgreSQL 18 Backup Restore
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

USER_NAME="$(oc whoami)"
NAMESPACE="workshop-${USER_NAME}"
CLUSTER_NAME="pg-${USER_NAME}"
RESTORE_CLUSTER="${CLUSTER_NAME}-restore"
RESTORE_MANIFEST="cluster-restore.yaml"

show_instruct() {
  ui_note "
# 09 / PostgreSQL Backup Restore

Restore PostgreSQL 18 from MinIO using native Barman Object Store.

## Objectives
- Verify the available backups
- Create a recovery cluster with one PostgreSQL instance
- Observe PostgreSQL recovery
- Verify restored data and cluster health

## Expected outcome
A new PostgreSQL 18 cluster is running from the existing backup.

## Important
- The source cluster remains unchanged.
- The backup must be compatible with PostgreSQL 18.
- Recovery uses native Barman, not the plugin.
"
  ui_pause
}

play() {
  ui_info "Verify available backups"
  ui_command "oc get backups -n ${NAMESPACE}"
  ui_pause

  ui_info "Verify MinIO credentials"
  ui_command "oc get secret minio-creds -n ${NAMESPACE}"
  ui_pause

  ui_confirm "Create recovery cluster ${RESTORE_CLUSTER}?" || return 0

  ui_info "Create PostgreSQL recovery cluster"
  ui_command "oc apply -n ${NAMESPACE} -f ${RESTORE_MANIFEST}"
  ui_pause

  ui_info "Verify recovery cluster resource"
  ui_command "oc get cluster ${RESTORE_CLUSTER} -n ${NAMESPACE}"
  ui_pause

  ui_info "Observe recovery objects"
  ui_command "oc get pods,jobs,pvc -n ${NAMESPACE} -l k8s.enterprisedb.io/cluster=${RESTORE_CLUSTER}"
  ui_pause

  ui_info "Observe PostgreSQL recovery"
  ui_watch "oc get pods -n ${NAMESPACE} -l k8s.enterprisedb.io/cluster=${RESTORE_CLUSTER} -L k8s.enterprisedb.io/instanceRole"
  ui_pause

  ui_info "Verify PostgreSQL 18"
  ui_command "oc cnp psql ${RESTORE_CLUSTER} -n ${NAMESPACE} -- app -c \"SHOW server_version;\""
  ui_pause

  ui_info "Verify restored cluster status"
  ui_command "oc cnp status ${RESTORE_CLUSTER} -n ${NAMESPACE}"
  ui_pause

  ui_info "Verify PostgreSQL objects"
  ui_command "oc cnp psql ${RESTORE_CLUSTER} -n ${NAMESPACE} -- app -c \"\\dt\""
  ui_pause

  ui_success "PostgreSQL restore scenario completed."
  ui_info "Next scenario: 10"
}

main() {
  clear
  show_instruct
  play
}

main "$@"
