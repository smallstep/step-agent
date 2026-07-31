#!/usr/bin/env bash

set -e

DISTRO_CONTAINER_LIST=(fedora:latest redhat/ubi9:latest quay.io/centos/centos:stream9 almalinux:latest rockylinux/rockylinux:9.3.20231119 debian:latest ubuntu:latest archlinux:base)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Narrow the run to specific images, e.g. DISTROS="archlinux:base debian:latest"
if [[ -n "${DISTROS:-}" ]]; then
  read -ra DISTRO_CONTAINER_LIST <<< "${DISTROS}"
fi

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
  EXITCODE=0
  docker run --rm \
      --name "test-smallstep-agent-install-${DISTRO_NICKNAME}" \
      -e STEP_AGENT_TEAM=foo \
      -e DEBIAN_FRONTEND=noninteractive \
      -e TERM=xterm \
      -v "${SCRIPT_DIR}/../smallstep-agent-install.sh:/smallstep-agent-install.sh:Z" \
      "${DISTRO}" \
      bash -c "${PRE_CMD}./smallstep-agent-install.sh" || EXITCODE=$?

  if [[ "${EXITCODE}" -eq 0 ]]; then
    TEST_REPORT+=("${DISTRO}: Passed!")
  else
    TEST_REPORT+=("${DISTRO}: Failed! (exit ${EXITCODE})")
    FAILURES=$((FAILURES + 1))
  fi
done

echo ""
echo "Smallstep Agent Installer Test Report"
printf '%s\n' "${TEST_REPORT[@]}"

exit $(( FAILURES > 0 ? 1 : 0 ))
