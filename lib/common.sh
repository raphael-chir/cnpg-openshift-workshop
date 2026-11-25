#!/usr/bin/env bash
set -Eeuo pipefail

# Shared helper functions for the workshop scripts.
# Source lib/logger.sh first: these helpers use log_* and die.

have() { command -v "$1" >/dev/null 2>&1; }

# wait_until <timeout-seconds> <command...>: poll every 5s, return 1 on timeout.
wait_until() {
  local deadline=$((SECONDS + $1)); shift
  until "$@"; do
    (( SECONDS < deadline )) || return 1
    sleep 5
  done
}

# oc is installed and logged in. Shows which cluster and user the script is about to act on.
require_oc_login() {
  have oc || die "oc not found in PATH"
  oc whoami >/dev/null 2>&1 || die "not authenticated to OpenShift (run 'oc login')"
  log_info "Target cluster: $(oc whoami --show-server 2>/dev/null || echo unknown) (user: $(oc whoami))"
  log_success "OpenShift connection"
}

require_cluster_admin() {
  [[ "$(oc auth can-i '*' '*' --all-namespaces 2>/dev/null || true)" == "yes" ]] \
    || die "cluster-admin privileges required (oc auth can-i '*' '*' --all-namespaces)"
  log_success "Cluster-admin privileges"
}

# check_catalog <package> <catalog-source> <channel>: the OLM package is served by that
# catalog and offers that channel (read-only).
check_catalog() {
  local package="$1" catalog="$2" channel="$3" ns="openshift-marketplace" src channels
  src="$(oc -n "${ns}" get packagemanifest "${package}" -o 'jsonpath={.status.catalogSource}' 2>/dev/null || true)"
  [[ -n "${src}" ]] || die "package ${package} not found in ${ns}: is the ${catalog} catalog enabled and healthy? (oc get catalogsource -n ${ns})"
  [[ "${src}" == "${catalog}" ]] || die "package ${package} is served by catalog '${src}', expected '${catalog}'"
  channels="$(oc -n "${ns}" get packagemanifest "${package}" -o 'jsonpath={.status.channels[*].name}' 2>/dev/null || true)"
  [[ " ${channels} " == *" ${channel} "* ]] || die "channel '${channel}' not available for ${package} (available: ${channels:-none})"
  log_success "OLM catalog available (${catalog}/${package}, channel ${channel})"
}

# Return 0 if CRC reports the OpenShift cluster as Running. Read-only.
crc_is_running() {
  local out
  out="$(crc status -o json 2>/dev/null)" || return 1
  grep -Eq '"openshiftStatus"[[:space:]]*:[[:space:]]*"Running"' <<<"${out}"
}

# Make `oc` available on PATH using the output of `crc oc-env`.
# The output is parsed, never eval'ed. Nothing is started or reconfigured.
# Returns 0 if oc is usable afterwards, 1 otherwise.
init_oc_from_crc() {
  have oc && return 0
  have crc || return 1
  local line dir
  line="$(crc oc-env 2>/dev/null | grep -m1 '^export PATH=')" || return 1
  dir="${line#export PATH=\"}"
  dir="${dir%%:\$PATH\"*}"
  [[ -n "${dir}" && -d "${dir}" ]] || return 1
  PATH="${dir}:${PATH}"
  export PATH
  have oc && oc version --client >/dev/null 2>&1
}
