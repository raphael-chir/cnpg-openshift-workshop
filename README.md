[![Generic badge](https://img.shields.io/badge/Version-1.0.0--rc.1-blue.svg)](https://shields.io/)
[![Maintenance](https://img.shields.io/badge/Maintained%3F-yes-green.svg)](https://GitHub.com/Naereen/StrapDown.js/graphs/commit-activity)
![Maintainer](https://img.shields.io/badge/maintainer-raphael.chir@enterprisedb.com-blue)
# CNPG OpenShift Workshop

A hands-on workshop on EDB CloudNativePG (CNPG) running on OpenShift.

It runs on OpenShift Local (CRC) for development and testing, and on Red Hat
OpenShift Dev Spaces for participants, who only have namespace-scoped permissions.
Administrator scripts run from macOS (Apple Silicon) or Linux (amd64 or arm64).

## Status

| Part | State |
|---|---|
| Prerequisite checker (`setup/prereq.sh`) | implemented |
| EDB operator, MinIO and Dev Spaces installation | implemented |
| EDB CLI plugin installation | implemented |
| Participant provisioning (`setup/prepare-participant.sh`) | implemented (HTPasswd users, projects, admin role) |
| Devfile, scenarios, templates | placeholders |

## Requirements

- `oc`, logged in to the target cluster (`oc login`). The install scripts act on the **current context**
  and print the cluster and user before changing anything.
- Cluster-admin privileges for the administrator scripts.
- `helm` (MinIO installation), `curl` (CLI installation) and `htpasswd` (participant provisioning; included in macOS,
  package `httpd-tools` or `apache2-utils` on Linux).
- Outbound access to `raw.githubusercontent.com` and `github.com` (CLI plugin), `charts.min.io` (MinIO chart),
  Docker Hub (MinIO images) and `docker.enterprisedb.com` (EDB images). Mirrored or air-gapped clusters are not covered.
- A default StorageClass.
- `envsubst` (package `gettext`; on macOS `brew install gettext && brew link --force gettext`).
- Bash 3.2 or later (the macOS system bash is enough).

On OpenShift Local, make `oc` available and log in first:

```sh
eval $(crc oc-env)
oc login -u kubeadmin ...
```

## Administrator workflow

```sh
cp .env.example .env            # then set EDB_SUBSCRIPTION_TOKEN (never committed)

./setup/prereq.sh admin         # read-only checks; use "admin --crc" on OpenShift Local
./setup/install-operator.sh     # EDB CloudNativePG operator, through OLM
./setup/install-minio.sh        # MinIO in minio-system, bucket "cnpg"
./setup/install-devspaces.sh    # Red Hat OpenShift Dev Spaces
```

All scripts are safe to run again. Each prints its target and results through `lib/logger.sh`
(`NO_COLOR=1` disables colors). Exit codes: 0 success, 1 failure, 2 invalid arguments.

- **Operator:** installs from the `fast` channel of `certified-operators` (latest release) with automatic upgrades.
  The pull secret `postgresql-operator-pull-secret` is created from `EDB_SUBSCRIPTION_TOKEN`
  (exported, or in `.env`; an exported value wins). Without a token, an existing secret is reused.
- **MinIO:** credentials default to `admin` / `password`. Override with `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`;
  without overrides, the credentials already stored in the Secret `minio-root-credentials` are kept.
  Internal endpoint: `http://minio.minio-system.svc.cluster.local:9000`.
  On OpenShift the script also creates an edge-TLS Route `minio-console` for the console (an existing Route is kept; a Route pointing
  elsewhere only triggers a warning) and prints its URL, which you can read again with
  `oc get route minio-console -n minio-system -o jsonpath='https://{.spec.host}{"\n"}'`.
  Two ports: the **S3 API** is `minio:9000` (in-cluster only, used by PostgreSQL backups) and the **console** is `minio-console:9001`
  (the Route). The console login is the **MinIO** root user and password (`admin` / `password` by default, or the values in the
  Secret `minio-root-credentials`), not an OpenShift account. It is an administrative interface: outside an isolated lab, restrict
  access to it (network policy, VPN, or no Route).
- **Dev Spaces:** existing OperatorGroups, Subscriptions and CheClusters are never overwritten or deleted.
  An incompatible existing installation stops the script with an explanation.

## Participant workflow

Participants use Dev Spaces. `./setup/prereq.sh participant` checks a participant namespace
(set `EDB_PULL_SECRET_NAME` if the EDB pull secret has a custom name).

### Provisioning participants (administrator)

```sh
./setup/prepare-participant.sh --count 15                                  # developer01..developer15
./setup/prepare-participant.sh --count 15 --prefix developer --project-prefix workshop   # same, explicit
```

For each participant the script creates the OpenShift user, a dedicated project and a namespace-scoped `admin` role binding
(never cluster-admin; no SCC, operator, Dev Spaces, PostgreSQL or MinIO changes). It prints the table of users and projects
and checks that each project has a RoleBinding to the `admin` ClusterRole for its user; creating an EDB `Cluster` is tested after the first login.

| Count | User and password | Project |
|---|---|---|
| `--count 3` | `developer01`, `developer02`, `developer03` | `workshop-developer01`, `workshop-developer02`, `workshop-developer03` |

- **Prerequisites:** `oc` logged in as cluster-admin, `htpasswd`, and the EDB operator installed (`install-operator.sh`).
- **Authentication:** the cluster must already have an HTPasswd identity provider that uses the secret
  `openshift-config/htpass-secret` (key `htpasswd`). The script checks this and never edits the OAuth configuration. To create it once, put
  an initial file in that secret and add an entry like this with `oc edit oauth cluster` (keep your existing providers):
  `{name: developer, mappingMethod: claim, type: HTPasswd, htpasswd: {fileData: {name: htpass-secret}}}`.
  The script then downloads the file, adds only the missing users with bcrypt and replaces the `htpasswd` key. Existing users and
  their password hashes are preserved, so re-running never resets a password. OpenShift recreates the OAuth pod after the secret changes, so
  new credentials can take 1-2 minutes to work: a login that fails right after provisioning is expected, not an error (retry once the
  authentication operator is healthy again). The script does not wait for it.
- **Login = password:** each password equals the user name (`developer01` / `developer01`), and the script prints it. A user appears in
  OpenShift (`oc get users`) only after the first login; that is not an error.
- **Idempotent:** existing projects and role bindings are reused, missing ones are added, and `--count 20` after `--count 15` only adds
  `developer16` to `developer20`. If the secret update fails, no project is touched.
- **Warning:** predictable credentials are for an isolated, temporary training cluster only. Enterprise OpenShift environments usually
  use an external identity provider managed by Red Hat or the organization (LDAP, OIDC, ...): do not use this script there; create
  projects and role bindings with your own tooling instead.

## Command-line tools

The workshop uses `oc` for OpenShift, `oc cnp` for EDB CloudNativePG and `psql` for PostgreSQL.

Install the EDB CloudNativePG plugin locally (macOS or Linux, amd64 or arm64; no sudo, no cluster needed):

```sh
./setup/install-cnp-cli.sh
```

It installs `kubectl-cnp` v1.30.2 (the version matching the workshop's EDB operator 1.30.2) into `$HOME/bin`.
The version is pinned because the GitHub "latest" release can point to a release candidate that has no downloadable binaries.
To use another release, set `CNP_CLI_VERSION`:

```sh
CNP_CLI_VERSION=v1.30.2 ./setup/install-cnp-cli.sh
```

The script is safe to run again: a working installation is left untouched.
It never edits your shell configuration. If `$HOME/bin` is not in your `PATH`, add it yourself:

```sh
export PATH="$HOME/bin:$PATH"
```

Check the result with `command -v kubectl-cnp` and `oc cnp --help`.

`oc cnp` and `oc cnpg` are two different plugins:

- `oc cnp` runs the EDB plugin (`kubectl-cnp`), which is the one this workshop uses with the EDB operator.
- `oc cnpg` runs the community plugin (`kubectl-cnpg`). It is not installed by the workshop and is not interchangeable with the EDB one.

`./setup/prereq.sh participant` only checks that `kubectl-cnp` is available; it never installs anything.
