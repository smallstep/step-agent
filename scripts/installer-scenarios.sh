#!/usr/bin/env bash
#
# Runs INSIDE a distro container, driven by test-smallstep-agent-installer.sh.
# Exercises the installer twice on the same box and prints one RESULT line per
# scenario for the harness to collect:
#
#   install  fresh install of the latest stable release
#   upgrade  previous stable -> latest, via the installer, checking that the
#            package's post-install scriptlet actually ran on the upgrade
#
# Env (set by the harness): STEP_AGENT_TEAM, LATEST_VERSION, UPGRADE_FROM.

set -u

INSTALLER=/src/smallstep-agent-install.sh

# The probe is a side effect only the scriptlet produces: postinst writes the
# tss SupplementaryGroups drop-in iff group tss exists. Anything the package
# manager restores on its own (the step-agent user, /run/step-agent, ...) is
# useless here -- pacman's sysusers/tmpfiles hooks recreate those on every
# transaction and made an earlier version of this check pass on a broken
# package. The drop-in is touched by no libalpm hook, dpkg trigger or rpm
# filetrigger. The group is created up front so the probe applies on distros
# whose dependency set does not pull it in (deb/rpm do not depend on tpm2-tss).
PROBE=/etc/systemd/system/step-agent.service.d/tss.conf
getent group tss >/dev/null 2>&1 || groupadd tss

result() { echo "RESULT $1 $2"; }

installed_version() {
  local v=""
  if command -v pacman >/dev/null 2>&1; then
    v=$(pacman -Q step-agent 2>/dev/null | awk '{print $2}')
  elif command -v dpkg-query >/dev/null 2>&1; then
    v=$(dpkg-query -W -f '${Version}' step-agent 2>/dev/null)
  elif command -v rpm >/dev/null 2>&1; then
    v=$(rpm -q --qf '%{VERSION}' step-agent 2>/dev/null)
  fi
  # Drop the package release suffix: 0.69.2-1 -> 0.69.2.
  echo "${v%%-*}"
}

# Put the previous stable release in place the way a customer who installed
# it back then would have it, using the repo the installer just configured.
# Every stable version stays available in the apt and yum repos and in the
# versioned manifest tree, so the previous release is always reachable. The
# package release is always 1 (packageRelease in smallstep/agent's
# .goreleaser.yml).
downgrade_to() {
  local v="$1"
  if command -v pacman >/dev/null 2>&1; then
    local pkg
    pkg="step-agent-${v}-1-$(uname -m).pkg.tar.zst"
    curl -fsSL -o "/tmp/${pkg}" "https://packages.smallstep.com/stable/step-agent/linux/${v}/${pkg}" \
      && pacman -U --noconfirm "/tmp/${pkg}"
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --allow-downgrades "step-agent=${v}-1"
  elif command -v dnf >/dev/null 2>&1; then
    dnf downgrade -y "step-agent-${v}"
  else
    echo "no supported package manager found" >&2
    return 1
  fi
}

# --- install -----------------------------------------------------------------
echo "### scenario: install (fresh, expecting ${LATEST_VERSION})"
if ! "$INSTALLER"; then
  result install FAIL
  exit 1
fi
have=$(installed_version)
if [[ "$have" != "$LATEST_VERSION" ]]; then
  echo "installed ${have}, expected ${LATEST_VERSION}" >&2
  result install FAIL
  exit 1
fi
result install PASS

# Older packages (0.68.0 and before) call systemctl unguarded from their
# scriptlets and fail in a container that is not booted with systemd -- which
# aborts the dpkg configure step and leaves nothing to upgrade from. Current
# packages check for /run/systemd/system first. Laying down the previous
# release is only setup for the upgrade under test, so a no-op systemctl is
# put in place for that step alone and removed again before the installer
# runs the real upgrade. A container limitation, not something real hosts hit.
with_noop_systemctl() {
  local real
  real=$(command -v systemctl 2>/dev/null || echo /usr/bin/systemctl)
  [[ -e "$real" ]] && mv "$real" "${real}.real"
  printf '#!/bin/sh\nexit 0\n' > "$real" && chmod 0755 "$real"
  local rc=0
  "$@" || rc=$?
  rm -f "$real"
  [[ -e "${real}.real" ]] && mv "${real}.real" "$real"
  return "$rc"
}

# --- upgrade -----------------------------------------------------------------
echo "### scenario: upgrade (${UPGRADE_FROM} -> ${LATEST_VERSION})"
if ! with_noop_systemctl downgrade_to "$UPGRADE_FROM"; then
  echo "could not install previous release ${UPGRADE_FROM}" >&2
  result upgrade FAIL
  exit 1
fi
have=$(installed_version)
if [[ "$have" != "$UPGRADE_FROM" ]]; then
  echo "installed ${have} after downgrade, expected ${UPGRADE_FROM}" >&2
  result upgrade FAIL
  exit 1
fi

rm -f "$PROBE"

if ! "$INSTALLER"; then
  result upgrade FAIL
  exit 1
fi
have=$(installed_version)
if [[ "$have" != "$LATEST_VERSION" ]]; then
  echo "installed ${have} after upgrade, expected ${LATEST_VERSION}" >&2
  result upgrade FAIL
  exit 1
fi
if [[ ! -f "$PROBE" ]]; then
  echo "${PROBE} missing after upgrade: the package's install scriptlet did not run" >&2
  result upgrade FAIL
  exit 1
fi
result upgrade PASS
