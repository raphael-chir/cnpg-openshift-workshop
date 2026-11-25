# syntax=docker/dockerfile:1.7
# Lightweight multi-architecture (linux/amd64, linux/arm64) workspace image for the
# CNPG OpenShift workshop, for Red Hat OpenShift Dev Spaces (SCC restricted-v2).
#
# Build and publish (see README.md):
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -t quay.io/<username>/cnpg-workshop-devspaces:1.0 \
#     -f setup/devspaces-image/Dockerfile --push .

# UBI9 Minimal 9.9, pinned by tag and by multi-arch index digest.
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.9-1795198179@sha256:08d4c70f1baf6537a0728656cf7942d561e74a35916509d205b6519861266352

# Set by buildx: amd64 or arm64.
ARG TARGETARCH
# Pinned tool versions. All downloads are checked against upstream SHA-256 files.
ARG OC_VERSION=4.22.22
ARG KUBECTL_CNP_VERSION=1.30.2
ARG HELM_VERSION=3.22.1
# PostgreSQL client major version (PGDG packages). The latest minor of this major is installed.
ARG PG_MAJOR=17

LABEL org.opencontainers.image.title="cnpg-workshop-devspaces" \
      org.opencontainers.image.description="CNPG OpenShift workshop workspace image (oc, kubectl, kubectl-cnp, helm, psql)" \
      org.opencontainers.image.source="https://github.com/raphael-chir/cnpg-openshift-workshop" \
      org.opencontainers.image.base.name="registry.access.redhat.com/ubi9/ubi-minimal"

# 1. UBI packages, then the PostgreSQL client from PGDG.
#    The PGDG "postgresql<N>" package pulls systemd, libicu and util-linux (about 24 MB compressed)
#    that psql does not use, so the two client RPMs are installed without dependency resolution,
#    after their real library dependencies. The build fails if psql has an unresolved library.
RUN set -eux; \
    : "${TARGETARCH:?build with docker buildx (TARGETARCH is not set)}"; \
    microdnf install -y --setopt=install_weak_deps=0 --setopt=tsflags=nodocs \
        git-core jq gettext tar gzip less findutils procps-ng which ca-certificates \
        readline lz4-libs libzstd openldap krb5-libs openssl-libs zlib; \
    printf '[pgdg]\nname=PGDG %s\nbaseurl=https://download.postgresql.org/pub/repos/yum/%s/redhat/rhel-9-$basearch\nenabled=1\ngpgcheck=0\n' \
        "${PG_MAJOR}" "${PG_MAJOR}" > /etc/yum.repos.d/pgdg.repo; \
    for key in PGDG-RPM-GPG-KEY-RHEL PGDG-RPM-GPG-KEY-AARCH64-RHEL; do \
        rpm --import "https://download.postgresql.org/pub/repos/yum/keys/${key}"; \
    done; \
    tmp="$(mktemp -d)"; cd "${tmp}"; \
    microdnf download "postgresql${PG_MAJOR}" "postgresql${PG_MAJOR}-libs"; \
    rpm -K ./*.rpm; \
    rpm -ivh --nodeps ./*.rpm; \
    for tool in psql pg_dump pg_dumpall pg_restore pg_isready pgbench; do \
        ln -s "/usr/pgsql-${PG_MAJOR}/bin/${tool}" "/usr/local/bin/${tool}"; \
    done; \
    ! ldd "/usr/pgsql-${PG_MAJOR}/bin/psql" | grep 'not found'; \
    cd /; rm -rf "${tmp}" /etc/yum.repos.d/pgdg.repo; \
    microdnf clean all; \
    rm -rf /var/cache/* /var/log/* /tmp/*

# 2. Standalone CLIs in /usr/local/bin (outside /projects and /home/user, which Dev Spaces mounts over).
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) CNP_ARCH=x86_64 ;; \
        arm64) CNP_ARCH=arm64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    tmp="$(mktemp -d)"; cd "${tmp}"; \
    # oc + kubectl: one archive, pinned release (the x86_64 mirror path serves both architectures).
    oc_file="openshift-client-linux-${TARGETARCH}-rhel9-${OC_VERSION}.tar.gz"; \
    oc_base="https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${OC_VERSION}"; \
    curl -fsSL --retry 3 -O "${oc_base}/${oc_file}" -O "${oc_base}/sha256sum.txt"; \
    grep " ${oc_file}\$" sha256sum.txt | sha256sum -c -; \
    tar -xzf "${oc_file}" -C /usr/local/bin oc kubectl; \
    # kubectl-cnp: EDB plugin (not the community kubectl-cnpg), pinned release.
    cnp_file="kubectl-cnp_${KUBECTL_CNP_VERSION}_linux_${CNP_ARCH}.tar.gz"; \
    cnp_base="https://github.com/EnterpriseDB/kubectl-cnp/releases/download/v${KUBECTL_CNP_VERSION}"; \
    curl -fsSL --retry 3 -O "${cnp_base}/${cnp_file}" -O "${cnp_base}/kubectl-cnp-${KUBECTL_CNP_VERSION}-checksums.txt"; \
    grep " ${cnp_file}\$" "kubectl-cnp-${KUBECTL_CNP_VERSION}-checksums.txt" | sha256sum -c -; \
    tar -xzf "${cnp_file}" -C /usr/local/bin kubectl-cnp; \
    # helm: pinned release.
    helm_file="helm-v${HELM_VERSION}-linux-${TARGETARCH}.tar.gz"; \
    curl -fsSL --retry 3 -O "https://get.helm.sh/${helm_file}" -O "https://get.helm.sh/${helm_file}.sha256sum"; \
    sha256sum -c "${helm_file}.sha256sum"; \
    tar -xzf "${helm_file}" --strip-components=1 -C /usr/local/bin "linux-${TARGETARCH}/helm"; \
    chmod 0755 /usr/local/bin/oc /usr/local/bin/kubectl /usr/local/bin/kubectl-cnp /usr/local/bin/helm; \
    cd /; rm -rf "${tmp}"

# 3. OpenShift arbitrary-UID support, following the Red Hat documented pattern ("Support arbitrary user ids"):
#    - group 0 owns and can write the workspace and home directories;
#    - /etc/passwd (only, not /etc/group) is group-writable so the entrypoint can register the runtime UID.
#      whoami, ssh (git over SSH) and psql without an explicit user need a name for that UID.
#      restricted-v2 sets allowPrivilegeEscalation=false and drops all capabilities, so editing this file
#      cannot raise privileges; it only affects name resolution inside this one workspace container.
#    - setuid/setgid bits are removed as defense in depth (nothing in a workspace needs them).
RUN set -eux; \
    mkdir -p /projects /home/user; \
    echo "user:x:10001:0:user:/home/user:/bin/bash" >> /etc/passwd; \
    chgrp -R 0 /projects /home/user; \
    chmod -R g=u /projects /home/user; \
    chmod g=u /etc/passwd; \
    find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -exec chmod a-s {} +

COPY --chmod=0755 <<'EOF2' /usr/local/bin/entrypoint.sh
#!/bin/sh
# Register the arbitrary runtime UID (OpenShift restricted-v2) so whoami and ssh can resolve it.
# Skipped when the UID already resolves or /etc/passwd is not writable (the container still works).
if ! whoami >/dev/null 2>&1 && [ -w /etc/passwd ]; then
  echo "user:x:$(id -u):0:user:${HOME}:/bin/bash" >> /etc/passwd
fi
exec "$@"
EOF2

# 4. Build-time check of every required tool (runs under emulation for a foreign architecture).
RUN set -eux; \
    oc version --client; \
    kubectl version --client; \
    kubectl cnp --help >/dev/null; \
    oc cnp --help >/dev/null; \
    helm version; \
    psql --version | grep -F "(PostgreSQL) ${PG_MAJOR}."; \
    git --version; jq --version; envsubst --version | head -n1; \
    bash --version | head -n1; curl --version | head -n1; \
    tar --version | head -n1; gzip --version | head -n1; less --version | head -n1; \
    command -v ldd >/dev/null; find --version | head -n1; rpm --version

# SHELL lets the Dev Spaces editor terminal start bash even if the UID has no passwd entry.
ENV HOME=/home/user \
    SHELL=/bin/bash \
    LANG=C.UTF-8
WORKDIR /projects
USER 10001:0
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Keeps the workspace container alive; Dev Spaces runs the editor and terminals inside it.
CMD ["tail", "-f", "/dev/null"]
