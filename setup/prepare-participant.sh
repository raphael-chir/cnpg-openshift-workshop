#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup/prepare-participant.sh
# Provision workshop participants: HTPasswd users (password = user name), one project each,
# and the namespace-scoped admin role. Lab use only: predictable credentials are intentional
# (isolated, temporary training cluster).
# Prerequisites: oc logged in as cluster-admin, htpasswd, an HTPasswd identity provider using the secret below.
# Usage: ./setup/prepare-participant.sh [--count N] [--prefix NAME] [--project-prefix NAME]
# -----------------------------------------------------------------------------
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=workshop.env
source "${SCRIPT_DIR}/workshop.env"

AUTH_NS="openshift-config"
AUTH_SECRET="htpass-secret"
AUTH_KEY="htpasswd"
CLUSTER_OPS_ROLE="workshop-cluster-ops"

USERS=()
PROJECTS=()

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--count N] [--prefix NAME] [--project-prefix NAME]

  --count N               number of participants, 1-99 (default: ${PARTICIPANT_COUNT})
  --prefix NAME           user name prefix (default: ${USER_PREFIX}): ${USER_PREFIX}01, ${USER_PREFIX}02, ...
  --project-prefix NAME   project name prefix (default: ${PROJECT_PREFIX}): ${PROJECT_PREFIX}-${USER_PREFIX}01, ...

Adds the users to the HTPasswd secret ${AUTH_NS}/${AUTH_SECRET} (password = user name; existing users and
passwords are kept), creates one project per participant and grants the namespace-scoped admin role.
Lab use only. Needs oc (cluster-admin) and htpasswd.
USAGE
}

parse_args() {
  local name
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --count)          [[ $# -ge 2 ]] || { usage >&2; exit 2; }; PARTICIPANT_COUNT="$2"; shift 2 ;;
      --prefix)         [[ $# -ge 2 ]] || { usage >&2; exit 2; }; USER_PREFIX="$2"; shift 2 ;;
      --project-prefix) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; PROJECT_PREFIX="$2"; shift 2 ;;
      -h|--help)        usage; exit 0 ;;
      *)                usage >&2; exit 2 ;;
    esac
  done
  [[ "${PARTICIPANT_COUNT}" =~ ^[0-9]+$ ]] && [[ "${PARTICIPANT_COUNT}" -ge 1 && "${PARTICIPANT_COUNT}" -le 99 ]] \
    || { log_error "--count must be a number between 1 and 99"; usage >&2; exit 2; }
  for name in "${USER_PREFIX}" "${PROJECT_PREFIX}"; do
    [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] \
      || { log_error "prefixes must start with a letter and contain only a-z, 0-9 and '-': '${name}'"; usage >&2; exit 2; }
  done
  [[ $(( ${#PROJECT_PREFIX} + ${#USER_PREFIX} + 3 )) -le 63 ]] \
    || { log_error "prefixes too long: project names must stay within 63 characters"; exit 2; }
}

# Decoded htpasswd file of the secret, written to $1 (never printed).
download_htpasswd() {
  local b64
  b64="$(oc -n "${AUTH_NS}" get secret "${AUTH_SECRET}" -o "jsonpath={.data.${AUTH_KEY}}" 2>/dev/null)" \
    || die "cannot read secret ${AUTH_NS}/${AUTH_SECRET}"
  [[ -n "${b64}" ]] || die "secret ${AUTH_NS}/${AUTH_SECRET} has no '${AUTH_KEY}' key"
  printf '%s' "${b64}" | base64 --decode > "$1"
}

preflight() {
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
}

print_plan() {
  local i
  log_section "OpenShift Workshop — Participant Provisioning"
  echo "Identity provider: ${IDP}"
  echo "Participants:      ${PARTICIPANT_COUNT}"
  printf '%-14s%-14s%s\n' "USER" "PASSWORD" "PROJECT"
  for (( i = 0; i < PARTICIPANT_COUNT; i++ )); do
    printf '%-14s%-14s%s\n' "${USERS[$i]}" "${USERS[$i]}" "${PROJECTS[$i]}"
  done
}

# Keep every existing line (and hash); only add missing users; verify the secret afterwards.
update_htpasswd() {
  local user added=0
  download_htpasswd "${TMP}/htpasswd"
  # htpasswd appends to the last line when the file has no trailing newline (it would corrupt that entry): add one.
  [[ ! -s "${TMP}/htpasswd" || -z "$(tail -c1 "${TMP}/htpasswd")" ]] || printf '\n' >> "${TMP}/htpasswd"
  cp "${TMP}/htpasswd" "${TMP}/htpasswd.orig"
  for user in "${USERS[@]}"; do
    if grep -q "^${user}:" "${TMP}/htpasswd"; then
      continue
    fi
    htpasswd -bB "${TMP}/htpasswd" "${user}" "${user}" >/dev/null 2>&1 || die "htpasswd failed for user ${user}"
    added=$((added + 1))
  done
  # Never push an inconsistent file: every participant has its own line and every original line is untouched.
  for user in "${USERS[@]}"; do
    grep -q "^${user}:" "${TMP}/htpasswd" || die "htpasswd did not add ${user} to the local file; the secret was NOT updated"
  done
  if grep -vxFf "${TMP}/htpasswd" "${TMP}/htpasswd.orig" >/dev/null; then
    die "an existing htpasswd entry would be altered; the secret was NOT updated"
  fi
  if cmp -s "${TMP}/htpasswd" "${TMP}/htpasswd.orig"; then
    log_info "All ${PARTICIPANT_COUNT} users already exist in the secret: nothing to update"
  else
    # Documented OpenShift procedure. The file holds every existing user, so none is lost; the secret
    # content only travels through the pipe (never printed).
    oc -n "${AUTH_NS}" create secret generic "${AUTH_SECRET}" "--from-file=${AUTH_KEY}=${TMP}/htpasswd" \
        --dry-run=client -o yaml \
      | oc -n "${AUTH_NS}" replace -f - >/dev/null \
      || die "could not update secret ${AUTH_NS}/${AUTH_SECRET}; nothing else was changed"
    log_success "Secret ${AUTH_SECRET} updated: ${added} user(s) added, existing users kept (the OAuth server reloads in about a minute)"
  fi

  # Verify the secret really contains every participant.
  download_htpasswd "${TMP}/htpasswd.check"
  HTPASSWD_OK=OK
  for user in "${USERS[@]}"; do
    grep -q "^${user}:" "${TMP}/htpasswd.check" || { log_error "user ${user} missing from the secret"; HTPASSWD_OK=FAILED; }
  done
  [[ "${HTPASSWD_OK}" == OK ]] \
    || die "the secret was updated but does not contain every participant; no project was provisioned (inspect with 'oc -n ${AUTH_NS} get secret ${AUTH_SECRET}' and re-run)"
}

# Namespaced Role + RoleBinding for $1 (user) in $2 (project): the "admin" role does not cover the
# scale and status subresources of EDB clusters (needed by "oc scale" and "oc cnp promote").
# "oc apply" makes it idempotent.
apply_cluster_rbac() {
  oc apply -n "$2" -f - >/dev/null <<YAML || die "could not apply the cluster-ops Role/RoleBinding for $1 in $2"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${CLUSTER_OPS_ROLE}
  namespace: $2
rules:
  - apiGroups: ["postgresql.k8s.enterprisedb.io"]
    resources: ["clusters/scale", "clusters/status"]
    verbs: ["get", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${CLUSTER_OPS_ROLE}
  namespace: $2
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ${CLUSTER_OPS_ROLE}
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: $1
YAML
}

# One project per participant, with the namespace-scoped admin role (never cluster-admin).
create_projects() {
  local i user project
  for (( i = 0; i < PARTICIPANT_COUNT; i++ )); do
    user="${USERS[$i]}"; project="${PROJECTS[$i]}"
    if oc get namespace "${project}" >/dev/null 2>&1; then
      log_info "Project ${project} exists"
    else
      oc create namespace "${project}" >/dev/null || die "could not create project ${project}"
      log_success "Project ${project} created"
    fi
    oc adm policy add-role-to-user admin "${user}" -n "${project}" >/dev/null \
      || die "could not grant the admin role to ${user} in ${project}"
    apply_cluster_rbac "${user}" "${project}"
  done
}

# No logins and no impersonation: a User object only exists after first login.
# The EDB resource permission itself is checked when the participant logs in.
verify_projects() {
  local i user project
  PROJECTS_OK=OK
  RBAC_OK=OK
  for (( i = 0; i < PARTICIPANT_COUNT; i++ )); do
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
}

main() {
  local i user
  parse_args "$@"
  for (( i = 1; i <= PARTICIPANT_COUNT; i++ )); do
    user="$(printf '%s%02d' "${USER_PREFIX}" "${i}")"
    USERS+=("${user}")
    PROJECTS+=("${PROJECT_PREFIX}-${user}")
  done

  # Temporary files: private directory, always removed.
  TMP="$(umask 077; mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  trap 'exit 130' INT TERM

  preflight
  print_plan
  update_htpasswd
  create_projects
  verify_projects

  echo "HTPasswd: ${HTPASSWD_OK}"
  echo "Projects: ${PROJECTS_OK}"
  echo "RBAC:     ${RBAC_OK}"
  if [[ "${HTPASSWD_OK}" == OK && "${PROJECTS_OK}" == OK && "${RBAC_OK}" == OK ]]; then
    log_success "Provisioning completed."
    log_info "Note: OpenShift OAuth may take 1-2 minutes to activate new credentials."
  else
    die "Provisioning finished with errors (see above)"
  fi
}

main "$@"
