#!/bin/bash

# colors
BLACK="\033[0;30m"
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
MAGENTA="\033[0;35m"
CYAN="\033[0;36m"
WHITE="\033[0;37m"

BOLD="\033[1m"
RESET="\033[0m"

# arch
ARCH=$(rpm --eval '%{_arch}')
distro_id=''
distro_version=''

set -e

# This is here because we can't run linux32. If we fix that, we should remove this.
# If we remove this, we should revert the other change we did where we don't validate_not_set the target
# flag when IS_OL9_32BIT is true.
if [[ "$IS_OL9_32BIT" == "true" ]]; then
    target="i686"
fi

function setup_machine() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        echo "ID=$ID, VERSION_ID=$VERSION_ID"

        case "$ID" in
            centos)
                echo "Detected CentOS $VERSION_ID"
                distro_id='centos'
                distro_version=$VERSION_ID
                setup_centos
                ;;
            almalinux)
                echo "Detected AlmaLinux $VERSION_ID"
                distro_id='almalinux'
                distro_version=$VERSION_ID
                setup_alamalinux
                ;;
            alpine)
                echo "Detected Alpine $VERSION_ID"
                distro_id='alpine'
                distro_version=$VERSION_ID
                setup_alpine
                ;;
            *)
                error "Unknown distribution: $ID"
                ;;
        esac
    else
        error "/etc/os-release not found, cannot detect OS"
    fi
}

# centos setup
setup_centos() {
    # needed to run once on machine; in Dockerfile should be handled by it (must run as non-root user, but as sudoer)
    echo "performing machine setup, for distro: centos version: $distro_version"
    local machine_arch=$(uname -m)
    if [ $machine_arch = "x86_64" ]; then
        echo "64-bit architecture"
        sed -i 's/^\#baseurl=http:\/\/mirror.centos.org\/centos\/\$releasever\//baseurl=https:\/\/vault.centos.org\/7.9.2009\//' /etc/yum.repos.d/*
        sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|' /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo
    elif [[ $machine_arch == "i686" || $machine_arch == "i386" ]]; then
        echo "32-bit architecture"
        sed -i 's/^\#baseurl=http:\/\/mirror.centos.org\/altarch\/\$releasever\//baseurl=https:\/\/vault.centos.org\/altarch\/7.9.2009\//' /etc/yum.repos.d/*
    else
        error "Unsupported system architecture: \"$machine_arch\""
    fi
    sed -i 's/^mirrorlist/\#mirrorlist/' /etc/yum.repos.d/*

    # yum groupinstall "Development Tools" -y
    
    # for all
    # yum install sudo -y
    # yum install yum-utils -y
    # yum install which -y # required for libseccomp
    # yum install wget -y

    echo "finished centos setup"
}

# alamalinux setup
setup_alamalinux() {
    # needed to run once on machine; in Dockerfile should be handled by it (must run as non-root user, but as sudoer)
    echo "performing machine setup, for distro: alamalinux version: $distro_version"
    echo "finished alamalinux setup"
}

# alpine setup
setup_alamalinux() {
    # needed to run once on machine; in Dockerfile should be handled by it (must run as non-root user, but as sudoer)
    echo "performing machine setup, for distro: alpine version: $distro_version"
    echo "finished alpine setup"
}

# Handle --setup flag to run setup_machine and exit
if [[ "$1" == "--setup" ]]; then
    setup_machine
    exit
fi