#!/usr/bin/env bash
# Administrator script to prepare a participant namespace and permissions.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/logger.sh
source "${SCRIPT_DIR}/../lib/logger.sh"

die "Not implemented: prepare-participant.sh (participant namespaces, permissions and credentials are not available yet)"
