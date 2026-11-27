#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup/install-operator.sh
# Install or reconcile the EDB CloudNativePG Operator through OLM.
# Prerequisites: oc logged in as cluster-admin; EDB_SUBSCRIPTION_TOKEN (exported, or in .env at the repository
#   root) unless the pull secret already exists.
# Usage: ./setup/install-operator.sh
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

OPERATOR_NS="openshift-operators"
PACKAGE="cloud-native-postgresql"
CHANNEL="fast"
CATALOG="certified-operators"
SUBSCRIPTION_FILE="${SCRIPT_DIR}/operator-subscription.yaml"
PULL_SECRET="postgresql-operator-pull-secret"
REGISTRY="docker.enterprisedb.com"
REGISTRY_USER="k8s"
CRD="clusters.postgresql.k8s.enterprisedb.io"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Installs on the cluster oc is currently logged in to (any OpenShift cluster, cluster-admin required).

Token: EDB_SUBSCRIPTION_TOKEN, exported or set in .env (see .env.example).
An existing ${PULL_SECRET} is reused when no token is provided.
USAGE
}


preflight() {
  [[ -f "${SUBSCRIPTION_FILE}" ]] || die "manifest not found: ${SUBSCRIPTION_FILE}"
  require_oc_login
  require_cluster_admin
}

# Load EDB_SUBSCRIPTION_TOKEN from .env without executing it; an exported value wins.
load_token() {
  [[ -n "${EDB_SUBSCRIPTION_TOKEN:-}" ]] && return 0
  local envfile="${REPO_ROOT}/.env" line=""
  if [[ -f "${envfile}" ]]; then
    line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?EDB_SUBSCRIPTION_TOKEN=' "${envfile}" | tail -n1 || true)"
    line="${line#*EDB_SUBSCRIPTION_TOKEN=}"
    line="${line%$'\r'}"
    line="${line#\"}"; line="${line%\"}"; line="${line#\'}"; line="${line%\'}"
    EDB_SUBSCRIPTION_TOKEN="${line}"
  fi
  return 0
}

secret_exists() { oc -n "${OPERATOR_NS}" get secret "${PULL_SECRET}" >/dev/null 2>&1; }

# Create or update the pull secret. The token only travels through pipes (no argv, no file).
ensure_pull_secret() {
  if [[ -z "${EDB_SUBSCRIPTION_TOKEN:-}" ]]; then
    secret_exists || die "no EDB registry credentials: set EDB_SUBSCRIPTION_TOKEN (export it, or 'cp .env.example .env' and fill it) — secret ${PULL_SECRET} does not exist yet"
    log_success "EDB registry credentials (existing secret ${PULL_SECRET} reused)"
    return 0
  fi
  [[ "${EDB_SUBSCRIPTION_TOKEN}" =~ ^[A-Za-z0-9._~+/=-]+$ ]] \
    || die "EDB_SUBSCRIPTION_TOKEN contains unexpected characters (check .env for stray quotes or spaces)"
  local auth
  auth="$(printf '%s:%s' "${REGISTRY_USER}" "${EDB_SUBSCRIPTION_TOKEN}" | base64 | tr -d '\n')"
  printf '{"auths":{"%s":{"username":"%s","password":"%s","auth":"%s"}}}' \
      "${REGISTRY}" "${REGISTRY_USER}" "${EDB_SUBSCRIPTION_TOKEN}" "${auth}" \
    | oc -n "${OPERATOR_NS}" create secret generic "${PULL_SECRET}" \
        --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=/dev/stdin \
        --dry-run=client -o yaml \
    | oc apply --server-side --force-conflicts -f - >/dev/null \
    || die "could not create or update secret ${PULL_SECRET}"
  log_success "EDB registry credentials (secret ${PULL_SECRET} created/updated)"
}

check_conflicts() {
  local other
  other="$(oc get subscriptions.operators.coreos.com -A \
    -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.name}{"\n"}{end}' 2>/dev/null \
    | awk -v pkg="${PACKAGE}" -v ours="${OPERATOR_NS}/${PACKAGE}" '$2==pkg && $1!=ours {print $1}' || true)"
  [[ -z "${other}" ]] || die "conflict: ${PACKAGE} is already subscribed elsewhere (${other//$'\n'/, }); remove it first"
  if oc get crd "${CRD}" >/dev/null 2>&1 \
     && ! oc -n "${OPERATOR_NS}" get subscription.operators.coreos.com "${PACKAGE}" >/dev/null 2>&1; then
    # CRD without Subscription: tolerate a residual OLM-managed CRD, never touch it.
    local managed csvs deps
    managed="$(oc get crd "${CRD}" -o 'jsonpath={.metadata.labels.olm\.managed}' 2>/dev/null || true)"
    [[ "${managed}" == "true" ]] \
      || die "conflict: CRD ${CRD} exists but is not OLM-managed (Helm or manual install?); remove it first"
    csvs="$(oc get csv -A -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '/cloud-native-postgresql' || true)"
    deps="$(oc get deployments -A -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -E '/(postgresql-operator|cloud-native-postgresql)' || true)"
    [[ -z "${csvs}${deps}" ]] \
      || die "conflict: CRD ${CRD} is in use by an existing operator installation (${csvs:+CSV ${csvs//$'\n'/, }}${deps:+ Deployment ${deps//$'\n'/, }})"
    log_info "Residual OLM CRD detected — proceeding with installation."
  fi
}

apply_subscription() {
  local cur
  cur="$(oc -n "${OPERATOR_NS}" get subscription.operators.coreos.com "${PACKAGE}" \
    -o 'jsonpath={.spec.name}/{.spec.channel}/{.spec.source}' 2>/dev/null || true)"
  if [[ -n "${cur}" && "${cur}" != "${PACKAGE}/${CHANNEL}/${CATALOG}" ]]; then
    log_info "Existing Subscription differs (${cur}); aligning it with the manifest"
  fi
  oc apply -f "${SUBSCRIPTION_FILE}" >/dev/null || die "could not apply ${SUBSCRIPTION_FILE}"
  log_success "Subscription configured"
}

installed_csv() {
  oc -n "${OPERATOR_NS}" get subscription.operators.coreos.com "${PACKAGE}" -o 'jsonpath={.status.installedCSV}' 2>/dev/null
}
csv_phase() {
  oc -n "${OPERATOR_NS}" get csv "$1" -o 'jsonpath={.status.phase}' 2>/dev/null
}
have_installed_csv() { [[ -n "$(installed_csv)" ]]; }
csv_succeeded() { [[ "$(csv_phase "$1")" == "Succeeded" ]]; }

wait_csv() {
  local csv
  wait_until 300 have_installed_csv \
    || die "OLM did not resolve an installed CSV in 5 min (oc -n ${OPERATOR_NS} describe subscription ${PACKAGE})"
  csv="$(installed_csv)"
  wait_until 600 csv_succeeded "${csv}" \
    || die "CSV ${csv} did not reach Succeeded in 10 min (phase: $(csv_phase "${csv}" || true)); check 'oc -n ${OPERATOR_NS} get pods' for ImagePullBackOff and the pull secret"
  CSV="${csv}"
  log_success "Operator CSV Succeeded"
}

wait_deployment() {
  local dep
  dep="$(oc -n "${OPERATOR_NS}" get csv "${CSV}" -o 'jsonpath={.spec.install.spec.deployments[0].name}' 2>/dev/null || true)"
  [[ -n "${dep}" ]] || die "could not find the operator deployment in CSV ${CSV}"
  oc -n "${OPERATOR_NS}" rollout status "deployment/${dep}" --timeout=300s >/dev/null 2>&1 \
    || die "deployment ${dep} not ready in 5 min (check pods for ImagePullBackOff: oc -n ${OPERATOR_NS} get pods)"
  log_success "Operator deployment ready"
}

CSV=""
main() {
  [[ $# -eq 0 ]] || { usage >&2; exit 2; }

  preflight
  load_token
  ensure_pull_secret
  check_catalog "${PACKAGE}" "${CATALOG}" "${CHANNEL}"
  check_conflicts
  apply_subscription
  wait_csv
  wait_deployment
  wait_until 60 oc get crd "${CRD}" >/dev/null 2>&1 || die "CRD ${CRD} not registered after 60s"
  log_success "EDB CNPG CRD registered"

  log_success "EDB CloudNativePG Operator installed"
  log_info "Version: $(oc -n "${OPERATOR_NS}" get csv "${CSV}" -o 'jsonpath={.spec.version}' 2>/dev/null)"
  log_info "Namespace: ${OPERATOR_NS}"
}

main "$@"
