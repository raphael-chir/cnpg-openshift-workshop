#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup/install-minio.sh
# Install or reconcile MinIO (Helm chart 5.4.0) with the "cnpg" bucket.
# Prerequisites: oc logged in as cluster-admin, helm, a default StorageClass.
# Optional env: MINIO_ROOT_USER, MINIO_ROOT_PASSWORD (used only when set).
# Usage: ./setup/install-minio.sh
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

CHART_VERSION="5.4.0"
RELEASE="minio"
MINIO_NS="minio-system"
SECRET="minio-root-credentials"
BUCKET="cnpg"
VALUES="${SCRIPT_DIR}/values-minio.yaml"
ENDPOINT="http://${RELEASE}.${MINIO_NS}.svc.cluster.local:9000"
DEFAULT_USER="admin"
DEFAULT_PASSWORD="password"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Installs MinIO on the cluster oc is currently logged in to (any OpenShift cluster).

Optional env: MINIO_ROOT_USER, MINIO_ROOT_PASSWORD (default: existing Secret, else admin/password)
USAGE
}


b64()   { base64 | tr -d '\n'; }
unb64() { base64 --decode; }

# Value of a key in the existing credentials Secret (empty if absent). Never printed.
secret_field() {
  oc -n "${MINIO_NS}" get secret "${SECRET}" -o "jsonpath={.data.$1}" 2>/dev/null | unb64 2>/dev/null || true
}

preflight() {
  have helm || die "helm not found in PATH"
  [[ -f "${VALUES}" ]] || die "values file not found: ${VALUES}"
  require_oc_login
  local sc
  sc="$(oc get storageclass \
    -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | head -n1 || true)"
  [[ -n "${sc}" ]] || die "no default StorageClass found"
  log_success "Prerequisites (default StorageClass: ${sc})"
}

ensure_namespace() {
  if oc get namespace "${MINIO_NS}" >/dev/null 2>&1; then
    log_info "Namespace ${MINIO_NS} exists"
  else
    oc create namespace "${MINIO_NS}" >/dev/null || die "could not create namespace ${MINIO_NS}"
    log_success "Namespace ${MINIO_NS} created"
  fi
}

# Resolve effective credentials (env override > existing Secret > defaults), apply the Secret.
# Sets CREDS_CHANGED=1 if an existing Secret's content changed. Credentials go through stdin only.
CREDS_CHANGED=0
ensure_credentials() {
  local old_user old_pass user pass
  old_user="$(secret_field rootUser)"
  old_pass="$(secret_field rootPassword)"
  user="${MINIO_ROOT_USER:-${old_user:-${DEFAULT_USER}}}"
  pass="${MINIO_ROOT_PASSWORD:-${old_pass:-${DEFAULT_PASSWORD}}}"
  [[ "${#pass}" -ge 8 ]] || die "MinIO root password must be at least 8 characters"

  if [[ -n "${old_user}${old_pass}" && ( "${user}" != "${old_user}" || "${pass}" != "${old_pass}" ) ]]; then
    CREDS_CHANGED=1
  fi
  {
    printf '{"apiVersion":"v1","kind":"Secret","metadata":{"name":"%s","namespace":"%s"},"type":"Opaque","data":{"rootUser":"%s","rootPassword":"%s"}}' \
      "${SECRET}" "${MINIO_NS}" "$(printf '%s' "${user}" | b64)" "$(printf '%s' "${pass}" | b64)"
  } | oc apply -f - >/dev/null || die "could not create or update secret ${SECRET}"
  log_success "Secret ${SECRET} up to date"
}

install_chart() {
  log_info "Installing MinIO chart ${CHART_VERSION}"
  helm repo add minio https://charts.min.io/ --force-update >/dev/null \
    || die "could not add the MinIO Helm repository (network access to charts.min.io?)"
  helm upgrade --install "${RELEASE}" minio/minio \
    --namespace "${MINIO_NS}" --version "${CHART_VERSION}" \
    --values "${VALUES}" --hide-notes --wait --timeout 10m >/dev/null \
    || die "helm upgrade --install failed (see: helm -n ${MINIO_NS} status ${RELEASE}; oc -n ${MINIO_NS} get pods)"
  log_success "Helm release ${RELEASE} deployed"
}

verify_bucket() {
  local i
  for (( i = 1; i <= 20; i++ )); do
    if oc -n "${MINIO_NS}" exec "deploy/${RELEASE}" -- test -d "/export/${BUCKET}" 2>/dev/null; then
      log_success "Bucket ${BUCKET} exists"; return 0
    fi
    sleep 3
  done
  die "Bucket ${BUCKET} not found in MinIO"
}

# OpenShift only: expose the console (service <release>-console, port 9001) through an edge Route.
# An existing Route is never modified; a Route pointing elsewhere only gets a warning.
ensure_console_route() {
  local svc="${RELEASE}-console" route="${RELEASE}-console" port=9001 apis target tls host scheme status="OK"
  apis="$(oc api-versions 2>/dev/null || true)"
  if ! grep -qx 'route.openshift.io/v1' <<<"${apis}"; then
    log_info "OpenShift Route API not available: console Route skipped"
    return 0
  fi
  oc -n "${MINIO_NS}" get service "${svc}" >/dev/null 2>&1 || die "service ${svc} not found in ${MINIO_NS}"
  if oc -n "${MINIO_NS}" get route "${route}" >/dev/null 2>&1; then
    log_info "Route ${route} exists: kept unchanged"
  else
    oc -n "${MINIO_NS}" create route edge "${route}" --service="${svc}" --port="${port}" >/dev/null \
      || die "could not create Route ${route} in ${MINIO_NS}"
    log_success "Route ${route} created"
  fi
  target="$(oc -n "${MINIO_NS}" get route "${route}" -o 'jsonpath={.spec.to.name}:{.spec.port.targetPort}' 2>/dev/null || true)"
  case "${target}" in
    "${svc}:${port}"|"${svc}:http") ;;
    *) status="CHECK (Route targets '${target}', expected ${svc}:${port})"
       log_warn "Route ${route} points to '${target}', not ${svc}:${port}; it was left unchanged" ;;
  esac
  tls="$(oc -n "${MINIO_NS}" get route "${route}" -o 'jsonpath={.spec.tls.termination}' 2>/dev/null || true)"
  host="$(oc -n "${MINIO_NS}" get route "${route}" -o 'jsonpath={.spec.host}' 2>/dev/null || true)"
  [[ -n "${host}" ]] || die "Route ${route} has no host yet (oc -n ${MINIO_NS} get route ${route})"
  scheme="http"; [[ -n "${tls}" ]] && scheme="https"
  echo "MinIO Console"
  echo "-------------"
  echo "Namespace: ${MINIO_NS}"
  echo "Service:   ${svc}:${port}"
  echo "Route:     ${route}"
  echo "TLS:       ${tls:-none}"
  echo "URL:       ${scheme}://${host}"
  echo "Status:    ${status}"
}

main() {
  [[ $# -eq 0 ]] || { usage >&2; exit 2; }

  preflight
  ensure_namespace
  ensure_credentials

  # Root credentials are read at startup: restart a running MinIO before the chart's
  # bucket job connects with the new ones.
  if [[ "${CREDS_CHANGED}" -eq 1 ]] && oc -n "${MINIO_NS}" get deployment "${RELEASE}" >/dev/null 2>&1; then
    log_info "Credentials changed: restarting MinIO"
    oc -n "${MINIO_NS}" rollout restart "deployment/${RELEASE}" >/dev/null || die "could not restart ${RELEASE}"
    oc -n "${MINIO_NS}" rollout status "deployment/${RELEASE}" --timeout=300s >/dev/null \
      || die "deployment ${RELEASE} not ready after restart (oc -n ${MINIO_NS} get pods)"
  fi

  install_chart
  oc -n "${MINIO_NS}" rollout status "deployment/${RELEASE}" --timeout=300s >/dev/null \
    || die "deployment ${RELEASE} not ready in 5 min (oc -n ${MINIO_NS} get pods)"
  log_success "Deployment ${RELEASE} ready"
  verify_bucket
  log_info "MinIO internal endpoint: ${ENDPOINT}"
  ensure_console_route
}

main "$@"
