# Dev Spaces workspace image

Lightweight workspace image for the CNPG OpenShift workshop, for Red Hat OpenShift Dev Spaces.
It replaces the multi-gigabyte Universal Developer Image with a small UBI9 Minimal image that only
carries what the workshop scenarios use.

- **Base:** `registry.access.redhat.com/ubi9/ubi-minimal` 9.9, pinned by tag and index digest.
- **Architectures:** `linux/amd64` and `linux/arm64` from one Dockerfile and one image reference.
- **Size (compressed, measured locally):** about 153 MB (amd64) and 134 MB (arm64).

## Installed tools

| Tool | Version | Source |
|---|---|---|
| `oc`, `kubectl` | 4.22.22 / v1.35.2 (bundled) | `mirror.openshift.com`, pinned release, SHA-256 checked |
| `kubectl-cnp` (EDB) | 1.30.2 | GitHub release, SHA-256 checked. Works as `kubectl cnp` and `oc cnp` |
| `helm` | 3.22.1 | `get.helm.sh`, SHA-256 checked |
| `psql` and `pg_dump`, `pg_dumpall`, `pg_restore`, `pg_isready`, `pgbench` | PostgreSQL 17.x client | PGDG RPMs, signature checked |
| `git` (`git-core`), `jq`, `envsubst` (`gettext`), `bash`, `curl`, `tar`, `gzip`, `less` | UBI9 packages | UBI repositories |
| `find`, `ps`, `watch`, `which`, `ca-certificates` | UBI9 packages | needed by the Dev Spaces editor and the workshop |
| `clear`, `tput` (`ncurses`), `bash-completion` | UBI9 packages | terminal usability (about 0.5 MB compressed with the configuration) |

Versions are Dockerfile build arguments (`OC_VERSION`, `KUBECTL_CNP_VERSION`, `HELM_VERSION`, `PG_MAJOR`).
To move to PostgreSQL 18 clients later, build with `--build-arg PG_MAJOR=18` (the build fails if `psql` cannot run).
The PostgreSQL client RPMs are installed without dependency resolution: the PGDG package would otherwise pull
`systemd`, `libicu` and `util-linux` (about 24 MB) that `psql` does not use.

## Build and publish

Needs Docker Buildx. Building the foreign architecture runs under emulation (Docker Desktop provides it).

```sh
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t quay.io/<username>/cnpg-workshop-devspaces:1.1 \
  -f setup/devspaces-image/Dockerfile \
  --push .
```

`docker login quay.io` first, and make the Quay.io repository public so the cluster can pull it.
The tag is one OCI image index: OpenShift selects the architecture of each node. Nothing is published by the repository.

## Devfile

`devfile.yaml` at the repository root references this image in a single `tools` container with `mountSources: true`.
Replace `<username>` with the Quay.io account. The repository `devfile.yaml` keeps pointing at the last published tag until a new
one is published. Do not set `command` or `args`: the image keeps itself alive (`tail -f /dev/null`) and its entrypoint registers the
runtime UID. The Dev Spaces editor is injected into this container.

## Terminal

Interactive Bash is configured by `bashrc` (installed as `/etc/profile.d/cnpg-workshop.sh`). The Dev Spaces editor starts Bash
interactively and reads only `~/.bashrc`, so the image ships a default `~/.bashrc` (RHEL skeleton, which loads `/etc/bashrc` and
`/etc/profile.d`); the entrypoint recreates it when a mounted home directory has none, and never overwrites an existing one.
Your own `~/.bashrc` and `~/.bashrc.d/*` run afterwards and win.

- **Prompt:** `user ~/dir (branch) $`, with the user in green, the directory in blue (last three levels), the Git branch in yellow,
  and a red `✗ <code>` before the prompt when the previous command failed. Example: `✗ 1 raphael /projects/workshop (main) $`.
- **User name:** `oc whoami` runs once when the shell starts (3 s timeout), never at each prompt. Without a login (or without `oc`)
  the Linux user name is shown. After `oc login` as another user, open a new terminal. Only a plain user name is displayed.
- **Git branch:** read locally (`git symbolic-ref`, short hash when detached); no network, and no Git process outside a work tree.
  The branch name is shown through a variable, so a hostile branch name is never executed by the prompt.
- **Commands:** `clear`, `ll` (`ls -alF`), `la` (`ls -A`), `ls` and `grep` with `--color=auto`.
- **History:** `~/.bash_history` (5000 lines in memory, 10000 on disk), consecutive duplicates ignored, written after every command,
  Ctrl+R search. Kept only when the home directory is writable.
- **Completion:** `bash-completion` plus `oc`, `kubectl` and `helm` scripts generated at build time; they load on first Tab, so shell
  start-up is not slowed. There is no completion for `oc cnp`.

## OpenShift security model

- Runs as `USER 10001:0` and works under `restricted-v2` with an arbitrary UID: no root, no capabilities, no privilege escalation.
- `/projects` and `/home/user` are owned by group 0 with `g=u`. CLIs live in `/usr/local/bin`, outside the paths Dev Spaces mounts over.
- Setuid/setgid bits are removed from every file in the image (defense in depth; nothing in a workspace needs them).
- **`/etc/passwd` (only) is group-writable.** This is the pattern Red Hat documents for arbitrary UIDs: the entrypoint appends the
  runtime UID so that `whoami`, `ssh` (git over SSH) and `psql` without an explicit user can resolve it. `/etc/group` stays read-only.
  Under `restricted-v2` (`allowPrivilegeEscalation: false`, all capabilities dropped) editing the file cannot raise privileges;
  it only changes name resolution inside that one workspace container, and the change disappears with the container.
- **Not strictly required.** `psql` with `-U`, `PGUSER` or a connection URI works without any passwd entry (`~/.pgpass` is found through
  `$HOME`), and the editor terminal falls back to `$SHELL` (set to `/bin/bash`). If `/etc/passwd` is not writable the entrypoint skips
  the registration and the container still starts; only name lookups fail (`whoami`, `ssh`, `psql` with no user).
- `nss_wrapper` was evaluated and not used: it keeps both files read-only, but needs `LD_PRELOAD` and files created at start-up.
  Because the editor and terminals are started with the container environment (not the entrypoint's), the variables would have to be
  baked into the image, and if the entrypoint is bypassed every command prints `NWRAP_ERROR` and cannot resolve any user, including root.
  It also pulls a perl stack (about +11 MB compressed).

## Verify locally

```sh
IMG=quay.io/<username>/cnpg-workshop-devspaces:1.1     # or a locally built tag
docker run --rm --user 1000730000:0 --cap-drop ALL --security-opt no-new-privileges $IMG bash -lc '
  id; whoami
  oc version --client; kubectl version --client; kubectl cnp --help | head -n1; oc cnp --help | head -n1
  helm version --short; psql --version; git --version; jq --version; envsubst --version | head -n1
  touch /projects/x /home/user/x /tmp/x && echo writable'
```

Use `--platform linux/arm64` or `linux/amd64` to check each architecture. For the prompt, feed an interactive shell:
`printf 'false\nexit\n' | docker run --rm -i --user 1000730000:0 $IMG bash -i`.

## Verify on OpenShift

Reported working on Dev Spaces with ARM64 (image 1.0): workspace start, arbitrary UID, `oc whoami`, EDB CLI, PostgreSQL 17 and Helm.
Still to check for 1.1, in a real workspace:

1. The new prompt, `clear`, `ll`, `la`, colors and history in the Dev Spaces editor terminal (it may use shell integration).
2. The prompt user name after the automatic token injection (`oc whoami` at terminal start).
3. Tab completion for `oc`, `kubectl` and `helm`.
4. Git branch in the cloned project (Git may refuse a repository owned by another UID: "dubious ownership").
5. Pod SCC is `restricted-v2` (`oc get pod <pod> -o yaml | grep scc`).

## Known limitations

- Not yet tested inside a Dev Spaces workspace with this terminal configuration; the local tests use piped interactive shells and a Docker tty.
- `/etc/passwd` is group-writable (see above). The editor start script only edits `/etc/passwd` and `/etc/group` when `whoami` fails,
  which the entrypoint prevents.
- The latest minor of the PostgreSQL major is installed at build time (17.12 when tested); the other tools are pinned.
- The `oc` client 4.22 should stay within one minor version of the cluster.
- `kubectl-cnp` 1.30.2 does not accept `version --client`.
- The prompt user name is read once per shell: open a new terminal after switching OpenShift user.
