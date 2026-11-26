#!/usr/bin/env bash
# Provision workshop participants on OpenShift: HTPasswd users (password = user name),
# one project each, and the namespace-scoped admin role.
# Usage: ./setup/prepare-participant.sh [--count N] [--prefix NAME] [--project-prefix NAME]
# Lab use only: predictable credentials are intentional (isolated, temporary training cluster).
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

AUTH_NS="openshift-config"
AUTH_SECRET="htpass-secret"
AUTH_KEY="htpasswd"

COUNT=15
PREFIX="developer"
PROJECT_PREFIX="workshop"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--count N] [--prefix NAME] [--project-prefix NAME]

  --count N               number of participants, 1-99 (default: ${COUNT})
  --prefix NAME           user name prefix (default: ${PREFIX}): ${PREFIX}01, ${PREFIX}02, ...
  --project-prefix NAME   project name prefix (default: ${PROJECT_PREFIX}): ${PROJECT_PREFIX}-${PREFIX}01, ...

Adds the users to the HTPasswd secret ${AUTH_NS}/${AUTH_SECRET} (password = user name; existing users and
passwords are kept), creates one project per participant and grants the namespace-scoped admin role.
Lab use only. Needs oc (cluster-admin) and htpasswd.
USAGE
}

# --- arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)          [[ $# -ge 2 ]] || { usage >&2; exit 2; }; COUNT="$2"; shift 2 ;;
    --prefix)         [[ $# -ge 2 ]] || { usage >&2; exit 2; }; PREFIX="$2"; shift 2 ;;
    --project-prefix) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; PROJECT_PREFIX="$2"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *)                usage >&2; exit 2 ;;
  esac
done
[[ "${COUNT}" =~ ^[0-9]+$ ]] && [[ "${COUNT}" -ge 1 && "${COUNT}" -le 99 ]] \
  || { log_error "--count must be a number between 1 and 99"; usage >&2; exit 2; }
for name in "${PREFIX}" "${PROJECT_PREFIX}"; do
  [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] \
    || { log_error "prefixes must start with a letter and contain only a-z, 0-9 and '-': '${name}'"; usage >&2; exit 2; }
done
[[ $(( ${#PROJECT_PREFIX} + ${#PREFIX} + 3 )) -le 63 ]] \
  || { log_error "prefixes too long: project names must stay within 63 characters"; exit 2; }

USERS=()
PROJECTS=()
for (( i = 1; i <= COUNT; i++ )); do
  user="$(printf '%s%02d' "${PREFIX}" "${i}")"
  USERS+=("${user}")
  PROJECTS+=("${PROJECT_PREFIX}-${user}")
done

# --- temporary files: private directory, always removed
TMP="$(umask 077; mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
trap 'exit 130' INT TERM

# Decoded htpasswd file of the secret, written to $1 (never printed).
download_htpasswd() {
  local b64
  b64="$(oc -n "${AUTH_NS}" get secret "${AUTH_SECRET}" -o "jsonpath={.data.${AUTH_KEY}}" 2>/dev/null)" \
    || die "cannot read secret ${AUTH_NS}/${AUTH_SECRET}"
  [[ -n "${b64}" ]] || die "secret ${AUTH_NS}/${AUTH_SECRET} has no '${AUTH_KEY}' key"
  printf '%s' "${b64}" | base64 --decode > "$1"
}

# --- preflight
have htpasswd || die "htpasswd not found in PATH (macOS: included; Linux: httpd-tools or apache2-utils)"
require_oc_login
require_cluster_admin

# The identity provider must be the HTPasswd one that uses our secret: OAuth is never modified here.
IDP="$(oc get oauth cluster \
  -o 'jsonpath={range .spec.identityProviders[*]}{.name}{"|"}{.type}{"|"}{.htpasswd.fileData.name}{"\n"}{end}' 2>/dev/null \
  | awk -F'|' -v s="${AUTH_SECRET}" '$2 == "HTPasswd" && $3 == s { print $1; exit }')"
[[ -n "${IDP}" ]] \
  || die "OAuth 'cluster' has no HTPasswd identity provider using secret ${AUTH_NS}/${AUTH_SECRET}; configure it first (see README)"
log_success "HTPasswd identity provider '${IDP}' uses ${AUTH_NS}/${AUTH_SECRET}"

log_section "OpenShift Workshop — Participant Provisioning"
echo "Identity provider: ${IDP}"
echo "Participants:      ${COUNT}"
printf '%-14s%-14s%s\n' "USER" "PASSWORD" "PROJECT"
for (( i = 0; i < COUNT; i++ )); do
  printf '%-14s%-14s%s\n' "${USERS[$i]}" "${USERS[$i]}" "${PROJECTS[$i]}"
done

# --- HTPasswd: keep every existing line (and hash); only add missing users
download_htpasswd "${TMP}/htpasswd"
cp "${TMP}/htpasswd" "${TMP}/htpasswd.orig"
added=0
for user in "${USERS[@]}"; do
  if grep -q "^${user}:" "${TMP}/htpasswd"; then
    continue
  fi
  htpasswd -bB "${TMP}/htpasswd" "${user}" "${user}" >/dev/null 2>&1 || die "htpasswd failed for user ${user}"
  added=$((added + 1))
done
if cmp -s "${TMP}/htpasswd" "${TMP}/htpasswd.orig"; then
  log_info "All ${COUNT} users already exist in the secret: nothing to update"
else
  # Documented OpenShift procedure. The file holds every existing user, so none is lost; the secret
  # content only travels through the pipe (never printed).
  oc -n "${AUTH_NS}" create secret generic "${AUTH_SECRET}" "--from-file=${AUTH_KEY}=${TMP}/htpasswd" \
      --dry-run=client -o yaml \
    | oc -n "${AUTH_NS}" replace -f - >/dev/null \
    || die "could not update secret ${AUTH_NS}/${AUTH_SECRET}; nothing else was changed"
  log_success "Secret ${AUTH_SECRET} updated: ${added} user(s) added, existing users kept (the OAuth server reloads in about a minute)"
fi

# --- verify the secret really contains every participant
download_htpasswd "${TMP}/htpasswd.check"
HTPASSWD_OK=OK
for user in "${USERS[@]}"; do
  grep -q "^${user}:" "${TMP}/htpasswd.check" || { log_error "user ${user} missing from the secret"; HTPASSWD_OK=FAILED; }
done
[[ "${HTPASSWD_OK}" == OK ]] || die "the secret does not contain every participant; no project was provisioned"

# --- projects and namespace-scoped admin role (never cluster-admin)
for (( i = 0; i < COUNT; i++ )); do
  user="${USERS[$i]}"; project="${PROJECTS[$i]}"
  if oc get namespace "${project}" >/dev/null 2>&1; then
    log_info "Project ${project} exists"
  else
    oc create namespace "${project}" >/dev/null || die "could not create project ${project}"
    log_success "Project ${project} created"
  fi
  oc adm policy add-role-to-user admin "${user}" -n "${project}" >/dev/null \
    || die "could not grant the admin role to ${user} in ${project}"
done

# --- verification (no logins and no impersonation: a User object only exists after first login).
# The EDB resource permission itself is checked when the participant logs in.
PROJECTS_OK=OK
RBAC_OK=OK
for (( i = 0; i < COUNT; i++ )); do
  user="${USERS[$i]}"; project="${PROJECTS[$i]}"
  if ! oc get namespace "${project}" >/dev/null 2>&1; then
    log_error "project ${project} not found"; PROJECTS_OK=FAILED; RBAC_OK=FAILED; continue
  fi
  # Any RoleBinding of the project, whatever its name: roleRef ClusterRole/admin with this user as a subject.
  if ! oc -n "${project}" get rolebindings.rbac.authorization.k8s.io \
         -o 'jsonpath={range .items[*]}{.roleRef.kind}/{.roleRef.name}{"|"}{range .subjects[*]}{.kind}:{.name}{" "}{end}{"\n"}{end}' 2>/dev/null \
       | awk -F'|' -v u="User:${user}" '$1 == "ClusterRole/admin" { n = split($2, s, " "); for (k = 1; k <= n; k++) if (s[k] == u) found = 1 } END { exit !found }'; then
    log_error "no RoleBinding gives ${user} the admin ClusterRole in ${project}"; RBAC_OK=FAILED
  fi
done

echo "HTPasswd: ${HTPASSWD_OK}"
echo "Projects: ${PROJECTS_OK}"
echo "RBAC:     ${RBAC_OK}"
if [[ "${HTPASSWD_OK}" == OK && "${PROJECTS_OK}" == OK && "${RBAC_OK}" == OK ]]; then
  log_success "Provisioning completed."
  log_info "Note: OpenShift OAuth may take 1-2 minutes to activate new credentials."
else
  die "Provisioning finished with errors (see above)"
fi
