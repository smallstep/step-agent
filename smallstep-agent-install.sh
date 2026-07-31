#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Copyright (C) 2022 Smallstep Labs, Inc. All Rights Reserved.
#
# This script is the source of truth for the Smallstep agent Linux installer.
# It is also deployed to GCS and served at:
#   https://packages.smallstep.com/scripts/smallstep-agent-install.sh
#
# For GCS upload instructions, see the README in the packages.smallstep.com repo:
#   https://github.com/smallstep/packages.smallstep.com

set -eo pipefail

# tput fails when TERM is unset or dumb (cron, CI, `curl ... | sudo bash` from a
# provisioning system). Under `set -e` that would abort the install before it
# starts, so fall back to unstyled output instead.
bold=$(tput bold 2>/dev/null || true)
normal=$(tput sgr0 2>/dev/null || true)

helptext(){
cat <<'EOF'

                       smallstep-agent-install.sh
                Register smallstep agent on smallstep.com
                 or your smallstep run-anywhere cluster

                    https://smallstep.com/docs/agent

                          Copyright (C) 2025
                          Smallstep Labs, Inc
                          All Rights Reserved

                    SPDX-License-Identifier: Apache-2.0

     Example:
    ./smallstep-agent-install.sh --team example

    Required Flags or Environment Variables:
        --team example
        STEP_AGENT_TEAM=example

    Environment variables:

        STEP_AGENT_TEAM=example

    Configuration precedence for required variables:
    1) Flags
    2) Environment variables
    3) Prompts

    Notes:

    If this script was downloaded from inside your smallstep account
    it might have STEP_AGENT_TEAM automatically set. This will override
    the --team flag and the STEP_AGENT_TEAM environment variable and it
    will also disable promting for a team.

    Comment it out if you want to enable the --team flag, STEP_AGENT_TEAM
    environment variable, and prompting for a team when the script is run.

EOF
exit 0
}

if ! [ $(id -u) = 0 ]; then
   echo "This script must be run as root."
   exit 1
fi

# Get CPU Architecture
GNUARCH=$(uname -m)
case $GNUARCH in
    x86_64) ARCH="amd64" ;;
    x86) ARCH="386" ;;
    i686) ARCH="386" ;;
    i386) ARCH="386" ;;
    aarch64) ARCH="arm64" ;;
    armv5*) ARCH="armv5" ;;
    armv6*) ARCH="armv6" ;;
    armv7*) ARCH="armv7" ;;
esac

if [[ "${ARCH}" != "amd64" && "${ARCH}" != "arm64" ]]; then
    echo "This script only works on x86_64 and arm64 systems, for now."
    exit 1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --team)
            STEP_AGENT_TEAM="$2"
            shift
            shift
            ;;
        --help)
            helptext
            ;;
        *)
            shift
            ;;
    esac
done

## Start Template
# STEP_AGENT_TEAM={{ .TeamSlug }}
# Comment the line above to disable the team that was automatically set when
# it was downloaded from your smallstep account.
## End Template

if [[ -v STEP_AGENT_TEAM ]]; then
    TEAM=${STEP_AGENT_TEAM}
fi

if [ "$(grep -Ei 'fedora|redhat|centos|rocky|almalinux|debian|buntu|arch' /etc/*release)" ]; then

  DISTRO=$(grep ^ID= /etc/os-release | cut -d'=' -f2 | tr -d '"')

  if [[ "$DISTRO" =~ ^(rhel|centos|rocky|almalinux)$ ]]; then
    echo "Setting up the YUM/DNF repository for ${DISTRO}..."

    cat << EOT > /etc/yum.repos.d/smallstep.repo
[smallstep]
name=Smallstep
baseurl=https://packages.smallstep.com/stable/el/
enabled=1
repo_gpgcheck=0
gpgcheck=1
gpgkey=https://packages.smallstep.com/keys/smallstep-0x889B19391F774443.gpg
EOT

  dnf makecache
  dnf install --best -y step-agent
  fi

  if [[ "$DISTRO" == "fedora" ]]; then
    echo "Setting up the DNF repository for ${DISTRO}..."

    cat << EOT > /etc/yum.repos.d/smallstep.repo
[smallstep]
name=Smallstep
baseurl=https://packages.smallstep.com/stable/fedora/
enabled=1
repo_gpgcheck=0
gpgcheck=1
gpgkey=https://packages.smallstep.com/keys/smallstep-0x889B19391F774443.gpg
EOT

  dnf makecache
  dnf install --best -y step-agent
  fi

  if [ "$(grep -Ei 'debian|buntu' /etc/*release)" ]; then
    echo "Setting up the Apt repository for ${DISTRO}..."
    apt-get update && apt-get install -y --no-install-recommends curl vim gpg ca-certificates
    curl -fsSL https://packages.smallstep.com/keys/apt/repo-signing-key.gpg -o /etc/apt/trusted.gpg.d/smallstep.asc
    cat << EOT > /etc/apt/sources.list.d/smallstep.list
deb [signed-by=/etc/apt/trusted.gpg.d/smallstep.asc] https://packages.smallstep.com/stable/debian debs main
EOT
  apt-get update && apt-get -y install step-agent
  fi

  if [ "$(grep -Ei 'arch' /etc/*release)" ]; then
    echo "Installing step-agent for ${DISTRO}..."

    PKG_URL="https://packages.smallstep.com/stable/linux/step-agent_${ARCH}_latest.pkg.tar.zst"
    PKG_FILE="/tmp/step-agent_${ARCH}_latest.pkg.tar.zst"

    echo "Downloading step-agent..."
    curl -fsSL -o "$PKG_FILE" "$PKG_URL"

    # Refresh the sync databases so pacman can resolve step-agent's
    # dependencies (tpm2-tss, tpm2-openssl, desktop-file-utils, polkit,
    # p11-kit). Without this, `pacman -U` fails outright on a host whose
    # databases have never been populated.
    #
    # NOTE: this is a `-Sy` (refresh) rather than a `-Syu` (full upgrade), so
    # it leaves the host in Arch's discouraged "partial upgrade" state. The
    # alternative is upgrading every package on the box, which an agent
    # installer should not do unilaterally.
    pacman -Sy --noconfirm
    pacman -U --noconfirm "$PKG_FILE"
    rm -f "$PKG_FILE"
  fi

else
  echo "Only the following Linux distributions are supported at this time:"
  echo ""
  echo "Fedora, RHEL, Centos Stream, Rocky Linux, AlmaLinux, Debian, Ubuntu, and Arch Linux variants"
  exit 1
fi
echo ""
echo "The Smallstep agent has been installed!"
echo ""
step-agent version
echo ""

if [[ -f /.dockerenv ]] || [[ "$container" =~ ^(oci|podman)$ ]]; then
  echo ""
  echo "Container detected! Skipping enabling and starting step-agent systemd service!"
  echo ""
  exit 0
else
  echo ""
  echo "Enabling and starting step-agent.service..."
  systemctl enable --now step-agent.service
  systemctl enable --now step-agent-restart.path
fi

if [ -z "$TEAM" ]; then
  echo ""
  echo "To continue, register this device with your Smallstep team:"
  echo ""
  echo "${bold}sudo step-agent register <team-slug>${normal}"
  echo ""
else
  echo ""
  echo "To continue, register this device with your Smallstep team:"
  echo ""
  echo "${bold}sudo step-agent register ${TEAM}${normal}"
  echo ""
fi
