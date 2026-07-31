#!/usr/bin/env bash

set -e

DISTRO_CONTAINER_LIST=(fedora:latest redhat/ubi9:latest quay.io/centos/centos:stream9 almalinux:latest rockylinux/rockylinux:9.3.20231119 debian:latest ubuntu:latest archlinux:base gentoo/stage3:systemd)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Images we deliberately do NOT support. These are negative tests: the
# installer's supported-distro gate must reject them with exit 1, so a clean
# exit 1 is a PASS — it proves the gate still works. Any other outcome is a
# failure, including a successful install (which would mean we started
# installing onto a platform we don't ship for).
UNSUPPORTED_DISTRO_LIST=(gentoo/stage3:systemd)

# Narrow the run to specific images, e.g. DISTROS="archlinux:base debian:latest"
if [[ -n "${DISTROS:-}" ]]; then
  read -ra DISTRO_CONTAINER_LIST <<< "${DISTROS}"
fi

TEST_REPORT=()
FAILURES=0

for DISTRO in "${DISTRO_CONTAINER_LIST[@]}"; do
  DISTRO_NICKNAME="${DISTRO%%:*}"
  DISTRO_NICKNAME="${DISTRO_NICKNAME//\//-}"
  # Unsupported distros are expected to be rejected by the installer's gate.
  EXPECTED_EXIT=0
  for UNSUPPORTED in "${UNSUPPORTED_DISTRO_LIST[@]}"; do
    if [[ "${DISTRO}" == "${UNSUPPORTED}" ]]; then
      EXPECTED_EXIT=1
    fi
  done

  if [[ "${EXPECTED_EXIT}" -eq 0 ]]; then
    echo "Testing smallstep-agent-install.sh on ${DISTRO_NICKNAME}..."
  else
    echo "Testing smallstep-agent-install.sh on ${DISTRO_NICKNAME} (expecting rejection)..."
  fi

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

  if [[ "${EXITCODE}" -eq "${EXPECTED_EXIT}" ]]; then
    if [[ "${EXPECTED_EXIT}" -eq 0 ]]; then
      TEST_REPORT+=("${DISTRO}: Passed!")
    else
      TEST_REPORT+=("${DISTRO}: Passed! (correctly rejected as unsupported)")
    fi
  else
    if [[ "${EXPECTED_EXIT}" -eq 0 ]]; then
      TEST_REPORT+=("${DISTRO}: Failed! (exit ${EXITCODE})")
    else
      TEST_REPORT+=("${DISTRO}: Failed! (expected rejection with exit 1, got exit ${EXITCODE})")
    fi
    FAILURES=$((FAILURES + 1))
  fi
done

echo ""
echo "Smallstep Agent Installer Test Report"
printf '%s\n' "${TEST_REPORT[@]}"

exit $(( FAILURES > 0 ? 1 : 0 ))
