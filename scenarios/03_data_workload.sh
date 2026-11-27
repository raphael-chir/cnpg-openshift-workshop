#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 03
# Data & Workload
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

USER_NAME="$(oc whoami)"
NAMESPACE="workshop-${USER_NAME}"
CLUSTER_NAME="pg-${USER_NAME}"

# Configure EDB registry access for pgbench Jobs
oc secrets link default "${CLUSTER_NAME}-pull" --for=pull >/dev/null

show_instruct() {
  ui_note "
# 03 / Data & Workload

Connect to PostgreSQL, initialize a dataset and generate a workload.

## What you will learn
- Discover EDB CloudNativePG CLI commands
- Connect to PostgreSQL using psql
- Initialize a pgbench dataset (100,000 accounts)
- Explore PostgreSQL tables and data
- Generate a workload and observe performance
- Reduce dataset size to optimize future backups

## Prerequisites
- Scenario 01 and 02 completed
- PostgreSQL cluster running with 3 instances

## Expected outcome
A PostgreSQL cluster populated with 1,000 accounts,
ready for backup, restore and high availability scenarios.
"
  ui_pause
}

play() {

  ui_info "Select your workshop project"
  ui_command "oc project ${NAMESPACE}"
  ui_pause

  ui_info "Explore EDB CloudNativePG CLI commands"
  ui_command "oc cnp --help"
  ui_pause

  ui_info "Connect to PostgreSQL and check the server version"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c 'SELECT version();'"
  ui_pause

  ui_info "Clean up previous pgbench jobs"
  ui_command "oc delete job pgb-init pgb-run --ignore-not-found"
  ui_pause

  ui_info "Initialize the pgbench dataset (100,000 accounts)"
  ui_command "oc cnp pgbench --job-name pgb-init ${CLUSTER_NAME} -- --initialize"
  ui_pause

  ui_info "Wait for dataset initialization"
  ui_command "oc wait --for=condition=complete job/pgb-init --timeout=300s"
  ui_pause

  ui_info "Explore PostgreSQL tables"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c '\dt'"
  ui_pause

  ui_info "Count pgbench accounts"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c 'SELECT count(*) FROM pgbench_accounts;'"
  ui_pause

  ui_info "Reduce dataset size to accelerate future backups"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c 'DELETE FROM pgbench_accounts WHERE aid > 1000;'"
  ui_pause

  ui_info "Reclaim disk space"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c 'VACUUM FULL pgbench_accounts;'"
  ui_pause

  ui_info "Verify remaining accounts"
  ui_command "oc cnp psql ${CLUSTER_NAME} -- app -c 'SELECT count(*) FROM pgbench_accounts;'"
  ui_pause

  ui_info "Verify PostgreSQL cluster health"
  ui_command "oc cnp status ${CLUSTER_NAME}"
  ui_pause

  ui_success "Dataset initialized, workload completed and data reduced."
  ui_info "Next scenario: 04_backup_restore.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"