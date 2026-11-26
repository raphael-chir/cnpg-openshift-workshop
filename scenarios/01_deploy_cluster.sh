#!/usr/bin/env bash
# CNPG Playground - Scenario 02
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/../lib/ui.sh"
# Participant project, derived from the user (the active project, e.g. developer10-devspaces, is not used).
NAMESPACE="workshop-$(oc whoami)"
${REPO_ROOT}/setup/init-workshop.sh

show_instruct() {
  ui_note "
# 01 / Deploy a PostgreSQL 17 cluster

Deploy a 3-instance PostgreSQL 17 cluster using CloudNativePG
and Barman cloud configuration to store WAL and backups in S3 Minio.

## Components
- PostgreSQL 17
- Barman Cloud
- MinIO object storage

## Objectives
1. Create MinIO credentials
2. Deploy PostgreSQL 17 cluster
3. Verify PostgreSQL instances and replication
4. Verify Barman Cloud integration

## Expected outcome
PostgreSQL 17 is operational with 3 instances,
and WAL archiving configured.
"
  ui_pause
}

play() {

  ui_info "Create MinIO credentials"
  ui_command "kubectl create secret generic minio-secret --from-literal=MINIO_ACCESS_KEY=admin --from-literal=MINIO_SECRET_KEY=password --dry-run=client -o yaml | kubectl apply -f -"
  ui_pause

  ui_info "Deploy PostgreSQL"
  ui_command "oc apply -n \"\${NAMESPACE}\" -f \"\${REPO_ROOT}/scenarios/manifests/cluster.yaml\""
  ui_pause

  ui_success "PostgreSQL 17 deployed ."
}

main() {
  clear
  show_instruct
  play
}

main "$@"
