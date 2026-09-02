#!/usr/bin/env bash

set -e

# almalinux is pinned to explicit majors rather than :latest so EL9 and EL10
# are each always covered — :latest silently drifts to the newest major.
DISTRO_CONTAINER_LIST=(fedora:latest redhat/ubi9:latest quay.io/centos/centos:stream9 almalinux:9 almalinux:10 rockylinux/rockylinux:9.3.20231119 debian:latest ubuntu:latest archlinux:base)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MANIFEST_URL="https://packages.smallstep.com/stable/step-agent/linux/index.json"

# Narrow the run to specific images, e.g. DISTROS="archlinux:base debian:latest"
if [[ -n "${DISTROS:-}" ]]; then
  read -ra DISTRO_CONTAINER_LIST <<< "${DISTROS}"
fi

# Each container runs two scenarios (see installer-scenarios.sh): a fresh
# install of the latest stable release, then an upgrade from the previous
# stable release to it. Both versions come from the manifest tree so the
# suite tracks releases on its own; UPGRADE_FROM overrides the starting point,
# e.g. UPGRADE_FROM=0.67.3 to reproduce a specific customer's upgrade path.
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to read ${MANIFEST_URL}" >&2
  exit 2
fi
read -r LATEST_VERSION PREVIOUS_VERSION < <(curl -fsSL "${MANIFEST_URL}" | python3 -c '
import json, sys
m = json.load(sys.stdin)
latest = m["latest_version"]
# versions[] is newest first and may include -rc builds, which never become
# latest and are not what customers upgrade from.
older = [v["version"] for v in m["versions"] if v["version"] != latest and "-rc" not in v["version"]]
print(latest, older[0] if older else "")
')
UPGRADE_FROM="${UPGRADE_FROM:-${PREVIOUS_VERSION}}"
if [[ -z "${LATEST_VERSION}" || -z "${UPGRADE_FROM}" ]]; then
  echo "could not resolve latest/previous versions from ${MANIFEST_URL}" >&2
  exit 2
fi
echo "Latest stable: ${LATEST_VERSION}; upgrade scenario starts from ${UPGRADE_FROM}"

TEST_REPORT=()
FAILURES=0

for DISTRO in "${DISTRO_CONTAINER_LIST[@]}"; do
  DISTRO_NICKNAME="${DISTRO%%:*}"
  DISTRO_NICKNAME="${DISTRO_NICKNAME//\//-}"
  echo "Testing smallstep-agent-install.sh on ${DISTRO_NICKNAME}..."

  # pacman 7 sandboxes its download worker with Landlock and drops to an
  # unprivileged 'alpm' user. Neither works inside a stock Docker container, so
  # pacman aborts before it can sync ("Landlock ruleset could not be applied" /
  # "switching to sandbox user 'alpm' failed"). Turn the sandbox off for the
  # test run only — this is a container limitation, not something real Arch
  # hosts hit, so the installer itself must not disable it.
  PRE_CMD=""
  case "${DISTRO}" in
    archlinux*)
      PRE_CMD="sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf && "
      ;;
  esac

  # The installer calls tput, which needs TERM. Passing it explicitly means we
  # don't have to allocate a TTY (`docker run -t`), which would break this
  # harness under CI where stdin is not a terminal.
  #
  # The scenario script reports each scenario on a "RESULT <name> PASS|FAIL"
  # line; the container's output is streamed and those lines picked out of it,
  # so a container that dies early simply reports fewer scenarios.
  #
  # The whole checkout is mounted rather than the two scripts individually: a
  # single-file bind mount is pinned to the inode it was first mounted from, and
  # Docker Desktop keeps serving that stale copy after the file is rewritten in
  # place. A directory mount always reflects the current contents.
  OUTPUT=$(docker run --rm \
      --name "test-smallstep-agent-install-${DISTRO_NICKNAME}" \
      -e STEP_AGENT_TEAM=foo \
      -e DEBIAN_FRONTEND=noninteractive \
      -e TERM=xterm \
      -e LATEST_VERSION="${LATEST_VERSION}" \
      -e UPGRADE_FROM="${UPGRADE_FROM}" \
      -v "${SCRIPT_DIR}/..:/src:ro,Z" \
      "${DISTRO}" \
      bash -c "${PRE_CMD}/src/scripts/installer-scenarios.sh" 2>&1 | tee /dev/stderr) || true

  for SCENARIO in install upgrade; do
    case "${SCENARIO}" in
      install) LABEL="install ${LATEST_VERSION}" ;;
      upgrade) LABEL="upgrade ${UPGRADE_FROM} -> ${LATEST_VERSION}" ;;
    esac
    if grep -qx "RESULT ${SCENARIO} PASS" <<< "${OUTPUT}"; then
      TEST_REPORT+=("${DISTRO} ${LABEL}: Passed!")
    elif grep -qx "RESULT ${SCENARIO} FAIL" <<< "${OUTPUT}"; then
      TEST_REPORT+=("${DISTRO} ${LABEL}: Failed!")
      FAILURES=$((FAILURES + 1))
    else
      TEST_REPORT+=("${DISTRO} ${LABEL}: Failed! (no result; container exited early)")
      FAILURES=$((FAILURES + 1))
    fi
  done
done

echo ""
echo "Smallstep Agent Installer Test Report"
printf '%s\n' "${TEST_REPORT[@]}"

exit $(( FAILURES > 0 ? 1 : 0 ))
