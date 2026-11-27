#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 04
# PostgreSQL Backup
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

USER_NAME="$(oc whoami)"
NAMESPACE="workshop-${USER_NAME}"
CLUSTER_NAME="pg-${USER_NAME}"
BACKUP_NAME="${CLUSTER_NAME}-backup"

show_instruct() {
  ui_note "
# 04 / PostgreSQL Backup

Explore PostgreSQL backup and WAL archiving using
EDB CloudNativePG and MinIO object storage.

## What you will learn
- Understand PostgreSQL backup configuration
- Discover WAL archiving
- Trigger an on-demand backup
- Monitor backup execution
- Explore Kubernetes Backup resources
- Verify backup storage in MinIO

## Prerequisites
- Scenario 01, 02 and 03 completed
- PostgreSQL cluster running
- MinIO object storage available

## Expected outcome
A completed PostgreSQL backup stored in MinIO,
ready for the restore scenario.
"
  ui_pause
}

play() {

  ui_info "Select your workshop project"
  ui_command "oc project ${NAMESPACE}"
  ui_pause

  ui_info "Explore PostgreSQL backup configuration"
  ui_command "oc get cluster ${CLUSTER_NAME} -o json | jq '.spec.backup'"
  ui_pause

  ui_info "Inspect PostgreSQL backup and WAL archiving status"
  ui_command "oc cnp status ${CLUSTER_NAME}"
  ui_pause

  ui_info "Explore existing PostgreSQL backups"
  ui_command "oc get backups"
  ui_pause

  ui_info "Remove previous workshop backup if present"
  ui_command "oc delete backup ${BACKUP_NAME} --ignore-not-found"
  ui_pause

  ui_info "Trigger an on-demand PostgreSQL backup"
  ui_command "oc cnp backup ${CLUSTER_NAME} --backup-name ${BACKUP_NAME} --method barmanObjectStore"
  ui_pause

  ui_info "Monitor PostgreSQL backup execution"
  ui_watch "oc get backup ${BACKUP_NAME}"
  ui_pause

  ui_info "Inspect PostgreSQL backup details"
  ui_command "oc describe backup ${BACKUP_NAME}"
  ui_pause

  ui_info "Verify PostgreSQL backup completion"
  ui_command "oc get backup ${BACKUP_NAME} -o jsonpath='{.status.phase}{\"\\n\"}'"
  ui_pause

  ui_info "Explore PostgreSQL backup history"
  ui_command "oc get backups -l k8s.enterprisedb.io/cluster=${CLUSTER_NAME}"
  ui_pause

  ui_info "Explore backup storage in MinIO"
  ui_note "
MinIO Console:

https://minio-console-minio-system.apps-crc.testing

Bucket: cnpg

Explore the backup objects created for your PostgreSQL cluster.

Note: MinIO is shared between workshop participants.
"
  ui_pause

  ui_success "PostgreSQL backup scenario completed."
  ui_info "Next scenario: 05_restore.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"