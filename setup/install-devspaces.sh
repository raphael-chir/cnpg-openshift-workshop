#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup/install-devspaces.sh
# Install or reconcile Red Hat OpenShift Dev Spaces through OLM (any OpenShift cluster).
# Prerequisites: oc logged in as cluster-admin.
# Never overwrites or deletes existing OperatorGroups, Subscriptions or CheClusters.
# Usage: ./setup/install-devspaces.sh
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

DEVSPACES_NS="openshift-devspaces"
PACKAGE="devspaces"
CHANNEL="stable"
CATALOG="redhat-operators"
CATALOG_NS="openshift-marketplace"
OPERATORGROUP="openshift-devspaces"
CHECLUSTER="devspaces"
CHE_CRD="checlusters.org.eclipse.che"
DWO_CRD="devworkspaces.workspace.devfile.io"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Installs Red Hat OpenShift Dev Spaces on the cluster oc is currently logged in to
(any OpenShift cluster, cluster-admin required). Existing resources are never overwritten.
USAGE
}

# Detect existing installations; fail on anything incompatible. Sets HAVE_* flags.
HAVE_NS=0; HAVE_OG=0; HAVE_SUB=0; HAVE_CHE=0
detect_existing() {
  local rows other n og

  # Subscription for the package anywhere other than our namespace.
  rows="$(oc get subscriptions.operators.coreos.com -A \
    -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.spec.name}{"\n"}{end}' 2>/dev/null || true)"
  other="$(awk -v pkg="${PACKAGE}" -v ns="${DEVSPACES_NS}/" '$2==pkg && index($1, ns)!=1 {print $1}' <<<"${rows}")"
  [[ -z "${other}" ]] || die "incompatible: Dev Spaces is already subscribed outside ${DEVSPACES_NS} (${other//$'\n'/, })"
  if awk -v pkg="${PACKAGE}" '$2==pkg {f=1} END{exit !f}' <<<"${rows}"; then HAVE_SUB=1; fi

  # CheClusters: at most one per cluster, and it must be ${DEVSPACES_NS}/${CHECLUSTER}.
  rows="$(oc get checluster.org.eclipse.che -A \
    -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
  other="$(grep -v "^${DEVSPACES_NS}/${CHECLUSTER}\$" <<<"${rows}" | sed '/^$/d' || true)"
  [[ -z "${other}" ]] || die "incompatible: another CheCluster exists (${other//$'\n'/, }); only one is supported per cluster"
  [[ -z "${rows}" ]] || HAVE_CHE=1

  if oc get namespace "${DEVSPACES_NS}" >/dev/null 2>&1; then
    HAVE_NS=1
    og="$(oc -n "${DEVSPACES_NS}" get operatorgroup.operators.coreos.com \
      -o 'jsonpath={range .items[*]}{.metadata.name}|{.spec.targetNamespaces[*]}|{.spec.selector}{"\n"}{end}' 2>/dev/null || true)"
    og="$(sed '/^$/d' <<<"${og}")"
    if [[ -n "${og}" ]]; then
      n="$(wc -l <<<"${og}" | tr -d ' ')"
      [[ "${n}" -eq 1 ]] || die "incompatible: ${n} OperatorGroups in ${DEVSPACES_NS} (OLM requires exactly one)"
      [[ "${og}" == *"||" ]] \
        || die "incompatible: OperatorGroup in ${DEVSPACES_NS} is not AllNamespaces (${og%%|*} has targetNamespaces or a selector)"
      HAVE_OG=1
    fi
  fi
  if [[ "${HAVE_NS}${HAVE_OG}${HAVE_SUB}${HAVE_CHE}" == "0000" ]]; then
    log_info "No existing Dev Spaces installation detected"
  else
    log_info "Existing resources detected (namespace=${HAVE_NS} operatorgroup=${HAVE_OG} subscription=${HAVE_SUB} checluster=${HAVE_CHE}); they will be kept"
  fi
}

ensure_namespace() {
  if [[ "${HAVE_NS}" -eq 1 ]]; then
    log_success "Namespace ${DEVSPACES_NS} exists"
  else
    oc create namespace "${DEVSPACES_NS}" >/dev/null || die "could not create namespace ${DEVSPACES_NS}"
    log_success "Namespace ${DEVSPACES_NS} created"
  fi
}

ensure_operatorgroup() {
  if [[ "${HAVE_OG}" -eq 1 ]]; then
    log_success "OperatorGroup exists (AllNamespaces)"
    return 0
  fi
  oc create -f - >/dev/null <<YAML || die "could not create OperatorGroup ${OPERATORGROUP}"
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OPERATORGROUP}
  namespace: ${DEVSPACES_NS}
spec: {}
YAML
  log_success "OperatorGroup ${OPERATORGROUP} created (AllNamespaces)"
}

ensure_subscription() {
  if [[ "${HAVE_SUB}" -eq 1 ]]; then
    local cur
    cur="$(oc -n "${DEVSPACES_NS}" get subscriptions.operators.coreos.com -o \
      'jsonpath={range .items[?(@.spec.name=="'"${PACKAGE}"'")]}{.spec.channel}/{.spec.source}{"\n"}{end}' 2>/dev/null | head -n1 || true)"
    [[ "${cur}" == "${CHANNEL}/${CATALOG}" ]] \
      || log_warn "Existing Subscription uses ${cur:-unknown} (expected ${CHANNEL}/${CATALOG}); keeping it unchanged"
    log_success "Subscription exists"
    return 0
  fi
  oc create -f - >/dev/null <<YAML || die "could not create Subscription ${PACKAGE}"
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${PACKAGE}
  namespace: ${DEVSPACES_NS}
spec:
  name: ${PACKAGE}
  channel: ${CHANNEL}
  source: ${CATALOG}
  sourceNamespace: ${CATALOG_NS}
  installPlanApproval: Automatic
YAML
  log_success "Subscription ${PACKAGE} created"
}

sub_csv() {
  oc -n "${DEVSPACES_NS}" get subscriptions.operators.coreos.com -o \
    'jsonpath={range .items[?(@.spec.name=="'"${PACKAGE}"'")]}{.status.installedCSV}{end}' 2>/dev/null
}
have_sub_csv() { [[ -n "$(sub_csv)" ]]; }
csv_succeeded() { [[ "$(oc -n "${DEVSPACES_NS}" get csv "$1" -o 'jsonpath={.status.phase}' 2>/dev/null)" == "Succeeded" ]]; }

wait_csv() {
  local csv
  wait_until 300 have_sub_csv \
    || die "OLM did not resolve an installed CSV in 5 min (oc -n ${DEVSPACES_NS} describe subscription)"
  csv="$(sub_csv)"
  wait_until 600 csv_succeeded "${csv}" \
    || die "CSV ${csv} did not reach Succeeded in 10 min (phase: $(oc -n "${DEVSPACES_NS}" get csv "${csv}" -o 'jsonpath={.status.phase}' 2>/dev/null || echo unknown)); see 'oc -n ${DEVSPACES_NS} get pods,installplan'"
  log_success "Dev Spaces CSV Succeeded (${csv})"
}

dwo_ready() {
  oc get csv -A -o 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name} {.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -Eq '/devworkspace-operator[^ ]* Succeeded$' && oc get crd "${DWO_CRD}" >/dev/null 2>&1
}

wait_dwo() {
  wait_until 300 dwo_ready \
    || die "DevWorkspace Operator dependency not ready in 5 min (expected a Succeeded devworkspace-operator CSV and CRD ${DWO_CRD}; check 'oc get csv -A')"
  log_success "DevWorkspace Operator ready"
}

che_crd_ready() { oc get crd "${CHE_CRD}" >/dev/null 2>&1; }

create_checluster_once() {
  oc create -f - >/dev/null 2>&1 <<YAML
apiVersion: org.eclipse.che/v2
kind: CheCluster
metadata:
  name: ${CHECLUSTER}
  namespace: ${DEVSPACES_NS}
spec: {}
YAML
}

ensure_checluster() {
  if [[ "${HAVE_CHE}" -eq 1 ]]; then
    log_success "CheCluster ${CHECLUSTER} exists"
    return 0
  fi
  wait_until 120 che_crd_ready || die "CRD ${CHE_CRD} not registered after 120s"
  # The CRD can be served before the operator webhook answers: retry briefly.
  wait_until 120 create_checluster_once || die "could not create CheCluster ${CHECLUSTER} (retried 120s)"
  log_success "CheCluster ${CHECLUSTER} created"
}

che_phase() { oc -n "${DEVSPACES_NS}" get checluster "${CHECLUSTER}" -o 'jsonpath={.status.chePhase}' 2>/dev/null; }
che_active() { [[ "$(che_phase)" == "Active" ]]; }

wait_checluster() {
  if ! wait_until 900 che_active; then
    log_error "CheCluster phase: $(che_phase || true) — $(oc -n "${DEVSPACES_NS}" get checluster "${CHECLUSTER}" -o 'jsonpath={.status.message} {.status.reason}' 2>/dev/null || true)"
    log_error "Pods in ${DEVSPACES_NS}:"
    oc -n "${DEVSPACES_NS}" get pods --no-headers 2>&1 | log_stream || true
    exit 1
  fi
  log_success "CheCluster Active"
}

dashboard_url() {
  local url host
  url="$(oc -n "${DEVSPACES_NS}" get checluster "${CHECLUSTER}" -o 'jsonpath={.status.cheURL}' 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    host="$(oc -n "${DEVSPACES_NS}" get route "${CHECLUSTER}" -o 'jsonpath={.spec.host}' 2>/dev/null || true)"
    [[ -z "${host}" ]] || url="https://${host}"
  fi
  [[ -n "${url}" ]] || die "CheCluster is Active but no dashboard URL was found"
  printf '%s' "${url}"
}

main() {
  [[ $# -eq 0 ]] || { usage >&2; exit 2; }

  require_oc_login
  require_cluster_admin
  detect_existing
  [[ "${HAVE_SUB}" -eq 1 ]] || check_catalog "${PACKAGE}" "${CATALOG}" "${CHANNEL}"
  ensure_namespace
  ensure_operatorgroup
  ensure_subscription
  wait_csv
  wait_dwo
  ensure_checluster
  wait_checluster
  log_success "Red Hat OpenShift Dev Spaces installed"
  log_info "Dashboard: $(dashboard_url)"
}

main "$@"
