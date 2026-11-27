#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 01
# Deploy a PostgreSQL cluster
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

# Participant environment
USER_NAME="$(oc whoami)"
NAMESPACE="workshop-${USER_NAME}"
CLUSTER_NAME="pg-${USER_NAME}"

# Initialize participant manifests
"${REPO_ROOT}/setup/init-workshop.sh"

show_instruct() {
  ui_note "
# 01 / Deploy PostgreSQL Cluster

Deploy a highly available PostgreSQL 17 cluster using EDB CloudNativePG
on OpenShift.

## Architecture
- 3 PostgreSQL instances
- 1 primary and 2 replicas
- Synchronous replication (ANY 1)

## Features
- Automatic failover
- Continuous WAL archiving to MinIO
- Dedicated data and WAL storage

## What you will learn
- Discover the EDB PostgreSQL Cluster API
- Explore a declarative PostgreSQL manifest
- Deploy a PostgreSQL cluster on OpenShift
- Monitor cluster initialization
- Identify primary and replica instances

## Expected outcome
A healthy PostgreSQL 17 cluster with three running instances.
"
  ui_pause
}

play() {

  ui_info "Identify your OpenShift user"
  ui_command "oc whoami"
  ui_pause

  ui_info "Select your workshop project"
  ui_command "oc project ${NAMESPACE}"
  ui_pause

  ui_info "Explore the EDB PostgreSQL Cluster API"
  ui_command "oc explain clusters.postgresql.k8s.enterprisedb.io.spec"
  ui_pause

  ui_info "Create credentials for MinIO object storage"
  ui_command "oc create secret generic minio-creds --from-literal=ACCESS_KEY_ID=admin --from-literal=ACCESS_SECRET_KEY=password --dry-run=client -o yaml | oc apply -f -"
  ui_pause

  ui_info "Explore the PostgreSQL cluster manifest"
  ui_command "cat manifests/cluster.yaml"
  ui_pause

  ui_info "Deploy the PostgreSQL cluster"
  ui_command "oc apply -f manifests/cluster.yaml"
  ui_pause

  ui_info "Monitor PostgreSQL cluster initialization"
  ui_watch "oc cnp status ${CLUSTER_NAME} -n ${NAMESPACE}"
  ui_pause

  ui_info "Verify PostgreSQL instances and their roles"
  ui_command "oc get pods -l cnpg.io/cluster=${CLUSTER_NAME} -L cnpg.io/instanceRole"
  ui_pause

  ui_info "Verify PostgreSQL cluster status"
  ui_command "oc get cluster ${CLUSTER_NAME}"
  ui_pause

  ui_success "PostgreSQL cluster deployment completed."
  ui_info "Next scenario: 02_explore_cluster.sh"
}

main() {
  clear
  show_instruct
  play
}

main "$@"