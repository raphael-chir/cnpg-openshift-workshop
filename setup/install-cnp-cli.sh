#!/usr/bin/env bash
# Install the EDB CloudNativePG kubectl plugin (kubectl-cnp) into $HOME/bin, without sudo.
# Usage: ./setup/install-cnp-cli.sh
# Local only: needs no cluster. Never edits shell configuration files.
# Not the community plugin: that one is kubectl-cnpg and is a different tool.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../lib/logger.sh
source "${REPO_ROOT}/lib/logger.sh"
# shellcheck source=../lib/common.sh
source "${REPO_ROOT}/lib/common.sh"

INSTALLER_URL="https://raw.githubusercontent.com/EnterpriseDB/kubectl-cnp/main/install.sh"
# Pinned: the GitHub "latest" release can point to a release candidate without assets.
# Matches the EDB CloudNativePG operator version. Override with CNP_CLI_VERSION.
VERSION="${CNP_CLI_VERSION:-v1.30.2}"
BIN_DIR="${HOME}/bin"
PLUGIN="kubectl-cnp"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Installs the EDB ${PLUGIN} plugin into \$HOME/bin (macOS or Linux, amd64 or arm64).
Skips the installation when a working ${PLUGIN} is already available.
Version: ${VERSION} by default; override with CNP_CLI_VERSION (for example v1.30.2).
USAGE
}

check_prerequisites() {
  local tool missing=()
  for tool in curl sh tar install mktemp uname; do
    have "${tool}" || missing+=("${tool}")
  done
  have sha256sum || have shasum || missing+=("sha256sum or shasum")
  [[ "${#missing[@]}" -eq 0 ]] || die "missing required tool(s): ${missing[*]}"

  [[ "${VERSION}" == v* ]] || VERSION="v${VERSION}"
  [[ "${VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] \
    || die "invalid CNP_CLI_VERSION '${VERSION}' (expected something like v1.30.2)"
  case "$(uname -s)" in Darwin|Linux) ;; *) die "unsupported OS: $(uname -s) (macOS and Linux only)" ;; esac
  case "$(uname -m)" in x86_64|amd64|arm64|aarch64) ;; *) die "unsupported architecture: $(uname -m) (amd64 and arm64 only)" ;; esac
  # A Rosetta shell on Apple Silicon reports x86_64: the amd64 binary would be installed.
  if [[ "$(uname -s)" == "Darwin" && "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == "1" ]]; then
    log_warn "Running under Rosetta: the amd64 plugin will be installed. Use a native arm64 terminal for the arm64 build."
  fi
  log_success "Prerequisites ($(uname -s)/$(uname -m))"
}

# Path of an existing plugin: the one in PATH, else the one in $BIN_DIR.
existing_plugin() {
  local p
  p="$(command -v "${PLUGIN}" 2>/dev/null || true)"
  [[ -n "${p}" ]] || { [[ -x "${BIN_DIR}/${PLUGIN}" ]] && p="${BIN_DIR}/${PLUGIN}"; }
  printf '%s' "${p}"
}

install_plugin() {
  local installer out
  log_info "Installing ${PLUGIN} ${VERSION}"
  mkdir -p "${BIN_DIR}" || die "cannot create ${BIN_DIR}"
  # Download fully first, then run: a cut connection never executes a partial script.
  installer="$(curl -fsSL --connect-timeout 10 --max-time 60 "${INSTALLER_URL}")" || die "could not download the installer from ${INSTALLER_URL}"
  [[ -n "${installer}" ]] || die "the downloaded installer is empty"
  if ! out="$(sh -s -- -b "${BIN_DIR}" "${VERSION}" <<<"${installer}" 2>&1)"; then
    log_error "EDB installer output (last lines):"
    tail -n 8 <<<"${out}" | log_stream
    die "the EDB installer failed for ${VERSION} (is the release published with binaries for this platform? network access to github.com? permissions on ${BIN_DIR}?)"
  fi
  [[ -x "${BIN_DIR}/${PLUGIN}" ]] || die "installer finished but ${BIN_DIR}/${PLUGIN} is missing"
  log_success "${PLUGIN} ${VERSION} installed in ${BIN_DIR}"
}

validate() {
  local bin
  if have "${PLUGIN}"; then
    bin="$(command -v "${PLUGIN}")"
    log_success "command -v ${PLUGIN}: ${bin}"
  else
    bin="${BIN_DIR}/${PLUGIN}"
    log_warn "${PLUGIN} is not in PATH yet"
  fi
  "${bin}" --help >/dev/null 2>&1 || die "${bin} --help failed"
  log_success "${PLUGIN} --help"

  if have oc; then
    # oc discovers plugins through PATH: check with $BIN_DIR included.
    PATH="${BIN_DIR}:${PATH}" oc cnp --help >/dev/null 2>&1 || die "'oc cnp --help' failed"
    log_success "oc cnp --help"
  else
    log_warn "oc not found: 'oc cnp' not checked (install oc, then run 'oc cnp --help')"
  fi

  case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *)
      log_warn "${BIN_DIR} is not in PATH. Add it to your shell, for example:"
      echo 'export PATH="$HOME/bin:$PATH"'
      ;;
  esac
}

main() {
  [[ $# -eq 0 ]] || { usage >&2; exit 2; }

  check_prerequisites
  local found
  found="$(existing_plugin)"
  if [[ -n "${found}" ]] && "${found}" --help >/dev/null 2>&1; then
    log_success "${PLUGIN} already installed (${found}), skipping installation"
  else
    [[ -z "${found}" ]] || log_warn "${found} exists but does not work; reinstalling into ${BIN_DIR}"
    install_plugin
  fi
  validate
  log_success "EDB ${PLUGIN} ready (use 'oc cnp'; 'oc cnpg' is the community plugin, not installed here)"
}

main "$@"
