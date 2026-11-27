#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 10
# Deploy a real-world application: Foot Cup Sim
# Phase 1: PostgREST on the existing PostgreSQL cluster, exposed through an HTTPS Route.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

USER_NAME="$(oc whoami)"
CLUSTER_NAME="pg-${USER_NAME}"
MANIFEST="${REPO_ROOT}/scenarios/manifests/foot-cup-sim.yaml"

# Initialize participant manifests
"${REPO_ROOT}/setup/init-workshop.sh"

clear
ui_note "
# 10 / Foot Cup Sim

Deploy a real-world application on top of your PostgreSQL cluster:
a World Cup simulator whose business logic lives in PostgreSQL.

## Architecture
- PostgreSQL: your existing EDB CloudNativePG cluster
- PostgREST: REST API generated from the PostgreSQL schema
- Swagger UI: interactive documentation of the API
- React UI: the simulator, in the browser

## What you will learn
- Connect an application to CloudNativePG with the generated Secret
- Deploy PostgREST and inspect its logs
- Expose a Service through an HTTPS Route
- Discover the Route URL from OpenShift

## Prerequisites
- Scenario 01 completed
- PostgreSQL cluster healthy

## Expected outcome
PostgREST running and reachable over HTTPS.
"
ui_pause

ui_info "Inspect the existing PostgreSQL resources"
ui_command "oc get cluster ${CLUSTER_NAME}"
ui_command "oc get service ${CLUSTER_NAME}-rw"
ui_command "oc get secret ${CLUSTER_NAME}-app"
ui_pause

ui_info "Explore the application manifest: PostgREST reads its database URI from the ${CLUSTER_NAME}-app Secret"
ui_command "cat ${MANIFEST}"
ui_pause

ui_info "Deploy PostgREST (only the resources labeled component=postgrest)"
ui_command "oc apply -f ${MANIFEST} -l app.kubernetes.io/component=postgrest"
ui_pause

ui_info "Inspect the PostgREST Pod and Service"
ui_command "oc get pods,services -l app.kubernetes.io/component=postgrest"
ui_pause

ui_info "Wait for the PostgREST rollout: the Pod is Ready only when PostgreSQL answers"
ui_command "oc rollout status deployment/postgrest --timeout=180s"
ui_pause

ui_info "Inspect the PostgREST logs"
ui_command "oc logs deployment/postgrest --tail=10"
ui_pause

ui_info "Expose PostgREST through an HTTPS Route"
ui_command "oc create route edge postgrest --service=postgrest --insecure-policy=Redirect"
ui_command "oc get route postgrest"
ui_pause

API_URL="https://$(oc get route postgrest -o jsonpath='{.spec.host}')"

ui_info "Configure the public OpenAPI URL"
ui_command "oc set env deployment/postgrest PGRST_OPENAPI_SERVER_PROXY_URI=${API_URL}"
ui_command "oc rollout status deployment/postgrest --timeout=180s"
ui_pause

ui_info "Test the REST API"
ui_command "curl -sk ${API_URL}/"
ui_pause

ui_success "PostgREST is running at ${API_URL}"
# Phase 2, in this order: database restore (Job + ConfigMap, before PostgREST), Swagger UI, React UI, CORS, simulation.
