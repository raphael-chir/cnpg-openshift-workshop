#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# CNPG OpenShift Workshop - Scenario 10
# Deploy a real-world application: Foot Cup Sim
# Reset and restore the application database (Job), then deploy PostgREST behind an HTTPS Route. Safe to run again.
# -----------------------------------------------------------------------------

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

source "${REPO_ROOT}/lib/ui.sh"

USER_NAME="$(oc whoami)"
CLUSTER_NAME="pg-${USER_NAME}"
DB_MANIFEST="${REPO_ROOT}/scenarios/manifests/foot-cup-sim-db.yaml"
MANIFEST="${REPO_ROOT}/scenarios/manifests/foot-cup-sim.yaml"
UI_MANIFEST="${REPO_ROOT}/scenarios/manifests/foot-cup-sim-ui.yaml"

# Initialize participant manifests
"${REPO_ROOT}/setup/init-workshop.sh"

clear
ui_note "
# 10 / Foot Cup Sim

Deploy a real-world application on your PostgreSQL cluster:
a World Cup simulator whose business logic lives in PostgreSQL.

## Architecture
- PostgreSQL: your existing EDB CloudNativePG cluster
- PostgREST: REST API generated from the database schema
- Swagger UI: interactive documentation of the API
- React UI: the simulator, in the browser

## What you will learn
- Reset and restore a database with a Kubernetes Job
- Connect an application with the generated Secret
- Expose a Service through an HTTPS Route
- Discover Route URLs from OpenShift
- Configure CORS for browser applications on other origins

## Important
- Every run resets schema public of the app database:
  all its tables, pgbench included, are deleted.
- The PostgreSQL cluster itself is never modified.
"
ui_pause

ui_info "Inspect the existing PostgreSQL cluster"
ui_command "oc get cluster ${CLUSTER_NAME}"
ui_pause

ui_info "Remove the previous database restoration Job"
ui_command "oc delete job worldcup-db-restore --ignore-not-found"
ui_pause

ui_info "Deploy the database dump and restoration Job"
ui_command "oc apply -f ${DB_MANIFEST}"
ui_pause

ui_info "Wait for database restoration"
ui_command "oc wait --for=condition=complete job/worldcup-db-restore --timeout=300s"
ui_pause

ui_info "Inspect database restoration logs"
ui_command "oc logs job/worldcup-db-restore"
ui_pause

ui_info "Deploy PostgREST"
ui_command "oc apply -f ${MANIFEST}"
ui_pause

ui_info "Wait for PostgREST readiness"
ui_command "oc rollout status deployment/postgrest --timeout=180s"
ui_pause

ui_info "Expose PostgREST through an HTTPS Route"
ui_command "oc create route edge postgrest --service=postgrest --insecure-policy=Redirect --dry-run=client -o yaml | oc apply -f -"
ui_pause

ui_info "Inspect the PostgREST Route"
ui_command "oc get route postgrest"
ui_pause

API_URL="https://$(oc get route postgrest -o jsonpath='{.spec.host}')"

ui_info "Configure the public OpenAPI URL"
ui_command "oc set env deployment/postgrest PGRST_OPENAPI_SERVER_PROXY_URI=${API_URL}"
ui_pause

ui_info "Wait for PostgREST readiness"
ui_command "oc rollout status deployment/postgrest --timeout=180s"
ui_pause

ui_info "Discover the available REST endpoints"
ui_command "curl -sk ${API_URL}/ | jq -r '.paths | keys[]'"
ui_pause

ui_info "Deploy Swagger UI and the React UI"
ui_command "oc apply -f ${UI_MANIFEST}"
ui_pause

ui_info "Expose Swagger UI through an HTTPS Route"
ui_command "oc create route edge worldcup-swagger --service=worldcup-swagger --insecure-policy=Redirect --dry-run=client -o yaml | oc apply -f -"
ui_pause

ui_info "Expose the React UI through an HTTPS Route"
ui_command "oc create route edge worldcup-ui --service=worldcup-ui --insecure-policy=Redirect --dry-run=client -o yaml | oc apply -f -"
ui_pause

SWAGGER_URL="https://$(oc get route worldcup-swagger -o jsonpath='{.spec.host}')"
UI_URL="https://$(oc get route worldcup-ui -o jsonpath='{.spec.host}')"

ui_info "Configure Swagger UI with the PostgREST OpenAPI URL"
ui_command "oc set env deployment/worldcup-swagger URL=${API_URL}/"
ui_pause

ui_info "Configure the React UI with the PostgREST API URL: the browser calls PostgREST directly"
ui_command "oc set env deployment/worldcup-ui API_URL=${API_URL}"
ui_pause

ui_info "Configure CORS: PostgREST accepts browser requests only from Swagger UI and the React UI"
ui_command "oc set env deployment/postgrest PGRST_SERVER_CORS_ALLOWED_ORIGINS=${SWAGGER_URL},${UI_URL}"
ui_pause

ui_info "Wait for PostgREST, Swagger UI and the React UI to be ready"
ui_command "oc rollout status deployment -l app.kubernetes.io/part-of=foot-cup-sim --timeout=180s"
ui_pause

ui_info "Verify the Swagger UI configuration"
ui_command "curl -sk ${SWAGGER_URL}/swagger-initializer.js | grep url"
ui_pause

ui_info "Verify the React UI runtime configuration"
ui_command "curl -sk ${UI_URL}/config.js"
ui_pause

ui_info "Verify the CORS preflight sent by the React UI before calling the API"
ui_command "curl -sk -i -X OPTIONS ${API_URL}/rpc/reset_tournament -H \"Origin: ${UI_URL}\" -H \"Access-Control-Request-Method: POST\" -H \"Access-Control-Request-Headers: content-type,prefer\" | grep -i access-control-allow"
ui_pause

ui_info "Verify the CORS preflight sent by Swagger UI"
ui_command "curl -sk -i -X OPTIONS ${API_URL}/teams -H \"Origin: ${SWAGGER_URL}\" -H \"Access-Control-Request-Method: GET\" | grep -i access-control-allow"
ui_pause

ui_success "Important : First Open PostgREST API URL and accept local certificate in you browser"
ui_success "Then open Swagger and Foot Cup Sim or refresh ... Enjoy "
ui_success "PostgREST API: ${API_URL}"
ui_success "Swagger UI:    ${SWAGGER_URL}"
ui_success "Foot Cup Sim:  ${UI_URL}"

ui_pause
