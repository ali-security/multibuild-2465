#!/bin/bash

# usefule refs/example:
#   - info for a package that contains src rpm link:
#       https://centos.pkgs.org/7/centos-updates-x86_64/python-2.7.5-92.el7_9.x86_64.rpm.html
#   - how to build SRPM
#       https://wiki.centos.org/HowTos(2f)RebuildSRPM.html
#   - SRPM repository
#       https://git.centos.org/rpms/python/releases
#   - rpmbuild man
#       https://linux.die.net/man/8/rpmbuild
#   - packaging guide
#       https://rpm-packaging-guide.github.io/
#   - rpmbuild/spec explanation
#       http://ftp.rpm.org/max-rpm/ch-rpm-b-command.html

# ASSUMES RUNNING FROM ~/
# usage
#       --name        {package-name-and-version-without-arch}
#       --url         {package-url}
#       --mode        {letters to pass to rpmbuild command}:
#                        bp: prep             - extract all and apply patches etc (for manually messing with the sources)
#                        bb: build binary     - build binary package RPM
#                        ba: build all        - also build SRPM, might run other code/tests
#       --patch       {path to patch to be added to folder} - can be repeated
#       --spec-patch  {spec file patch to apply}
#       --define      {macro definitions for rpm} - e.g. "dist .el7_9"
#       --zip          - zip output logs and files to build.zip
#       --metadata     - use metadata to gather name and patches instead of respective flags
#       --setup        - will install what is needed, use once before running on VM

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

set -e
######################## argument parsing ########################
srpm_url=
srpm_name=
build_mode=

new_patches=
internal_patches=
spec_patch=
define_flag=
define_value=
zip_output=
metadata_file=
target=
run_baseline=

# This is here because we can't run linux32. If we fix that, we should remove this.
# If we remove this, we should revert the other change we did where we don't validate_not_set the target
# flag when IS_OL9_32BIT is true.
if [[ "$IS_OL9_32BIT" == "true" ]]; then
    target="i686"
fi

# Gets the distro. In CentOS6 getting the distro is different from CentOS7+, so we need to check the version
get_distro() {
    _distro=$(cat /etc/*-release | grep ^ID= | cut -d= -f2)
    if [ "$_distro" == '' ]; then
        _distro=$(cat /etc/*-release | grep -Eo 'release [0-9]+\.[0-9]+' | head -n 1 | awk '{print $2}')
    fi
    echo "$_distro"
}

distro=$(get_distro)

setup_machine() {
    # needed to run once on machine; in Dockerfile should be handled by it (must run as non-root user, but as sudoer)
    echo -e "${YELLOW}SEAL${RESET}::: performing machine setup, for distro: $distro"
    # for centos
    machine_arch=$(uname -m)
    if [ "$distro" == '"centos"' ]; then
        # TODO: make sure the below changes run for centos 7
        if [ $machine_arch = "x86_64" ]; then
            echo "64-bit architecture"
            sed -i 's/^\#baseurl=http:\/\/mirror.centos.org\/centos\/\$releasever\//baseurl=https:\/\/vault.centos.org\/7.9.2009\//' /etc/yum.repos.d/*
        elif [[ $machine_arch == "i686" || $machine_arch == "i386" ]]; then
            echo "32-bit architecture"
            sed -i 's/^\#baseurl=http:\/\/mirror.centos.org\/altarch\/\$releasever\//baseurl=https:\/\/vault.centos.org\/altarch\/7.9.2009\//' /etc/yum.repos.d/*
        else
            echo "Unsupported system architecture: \"$machine_arch\""
            exit 1
        fi
        sed -i 's/^mirrorlist/\#mirrorlist/' /etc/yum.repos.d/*
        sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=https://vault.centos.org|' /etc/yum.repos.d/CentOS-SCLo-scl-rh.repo


        yum groupinstall "Development Tools" -y
    fi

    if [ "$distro" == '6.10' ] || [ "$distro" == '"rhel"' ]; then
        # Try to source the .env file for docker build
        if [ -f /run/secrets/envfile ]; then
            echo "Sourcing the .env file..."
            source /run/secrets/envfile
        else
            echo ".env file not found in /run/secrets/envfile, loading redhat credentials from env. variables..."
        fi

        # Ensure required environment variables are set, exit if not (README for details about RedHat credentials)
        if [ -z "$REDHATCP_USER" ]; then
            echo "Error: REDHATCP_USER is not set."
            exit 1
        fi

        if [ -z "$REDHATCP_PW" ]; then
            echo "Error: REDHATCP_PW is not set."
            exit 1
        fi

        if [ $machine_arch = "x86_64" ]; then
            # I have not tested this on anything other than x86_64 and do not want to cause a regression.
            # This might work fine on other archs
            sed -i 's/^\#baseurl=http:\/\/mirror.centos.org\/centos\/\$releasever\//baseurl=https:\/\/vault.centos.org\/6.10\//' /etc/yum.repos.d/*
            yum install -y wget
            wget -O /etc/yum.repos.d/epel-rhsm.repo http://repos.fedorapeople.org/repos/candlepin/subscription-manager/epel-subscription-manager.repo
        fi

        sed -i 's/^mirrorlist/\#mirrorlist/' /etc/yum.repos.d/*

        echo "Installing subscription-manager..."
        yum install -y subscription-manager
        echo "Done"

        # !! Change manually the location of the user and pw txt files when installing on Virtualbox VM in Azure. !!

        # Based on https://access.redhat.com/labs/registrationassistant/rhel6/1-3
        echo "Registering RedHat subscription..."
        # --force so it doesn't crash if there is already a subscription on the machine
        subscription-manager register --force --username="$REDHATCP_USER" --password="$REDHATCP_PW"
        echo "Attaching RedHat subscription (run subscription-manager list --available to find yours)..."
        SUBSCRIPTION_MANAGER_LIST_OUTPUT=$(subscription-manager list --available)
        POOL_ID=$(echo "$SUBSCRIPTION_MANAGER_LIST_OUTPUT" | awk '/Subscription Name:.*Red Hat Developer Subscription for Individuals/{flag=1} flag && /Pool ID:/ {print $NF; flag=0}')
        echo "Attaching to pool..."
        subscription-manager attach --pool=$POOL_ID
        # Enable required repositories
        echo "Enabling required repositories..."
        REPOS=(
            "rhel-6-server-rpms"
            "rhel-6-server-optional-rpms"
            "rhel-6-server-extras-rpms"
            "rhel-6-server-retired-els-rpms"
        )
        for REPO in "${REPOS[@]}"; do
            # in the rhel machine the rhel-6-server-retired-els-rpms is not available for some reason, therefore adding || true
            subscription-manager repos --enable="$REPO" || true
        done

        yum groupinstall "Development Tools" -y
        yum install tar -y

    fi

    # for oracle linux
    if [ "$distro" == '"ol"' ]; then
        if ! command -v yum &>/dev/null; then microdnf install -y yum; fi
        yum install epel-release -y
        yum groupinstall "Development Tools" -y
        olversion=$(cat /etc/*-release | grep ^VERSION_ID= | cut -d'"' -f2 | cut -d'.' -f1)
        yum-config-manager --enable ol${olversion}_appstream
        yum-config-manager --enable ol${olversion}_baseos_latest
        yum-config-manager --enable ol${olversion}_codeready_builder
    fi

    # for rhel9 and ol
    if [ "$distro" == '"rhel"' ] || [ "$distro" == '"ol"' ]; then
        yum install rpm-build -y
        yum install ncurses -y
        yum install git gcc autoconf automake make -y
    fi

    # for all
    yum install sudo -y
    yum install yum-utils -y
    yum install which -y # required for libseccomp
    yum install wget -y

    echo -e "${YELLOW}SEAL${RESET}::: finished setup"
}

validate_not_set() {
    if [[ "$1" != "" ]]; then
        echo -e "${RED}SEAL${RESET}::: $2 already set!"
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
    -u | --url)
        validate_not_set "$srpm_url" "srpm url"
        srpm_url="$2"
        shift
        shift
        ;;

    -n | --name)
        validate_not_set "$srpm_name" "srpm name"
        srpm_name="$2"
        shift
        shift
        ;;

    -t | --metadata)
        validate_not_set "$srpm_name" "srpm name"
        validate_not_set "$new_patches" "patches"
        validate_not_set "$spec_patch" "spec patch"
        metadata_file=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
        if [[ ! -f $metadata_file ]]; then
            echo -e "${RED}SEAL${RESET}::: metadata file $metadata_file does not exist"
            exit 1
        fi
        metadata_location=$(dirname $metadata_file)
        # use version because it always exists, whether it's sp1 or sp2
        version=$(jq -r '.library_version.version' $metadata_file)
        # remove the sp version
        version="${version%%+*}"
        # removing everything until the .el section from origin version
        origin_centos_ver="${version##*.el}"
        # removing everything after the `.` in case something used el7_9.1 in name
        # adding back .el prefix
        origin_centos_ver=".el${origin_centos_ver%%.*}"
        current_ver=$(rpm --eval "%dist")
        if [[ "$current_ver" != "$origin_centos_ver" ]]; then
            echo -e "${YELLOW}SEAL${RESET}::: targeting dist: $origin_centos_ver"
            validate_not_set "$define_flag" "define flag"
            define_flag="--define"
            define_value="dist $origin_centos_ver"
        fi

        srpm_name=$(jq -r '"\(.library.source_package // .library.escaped_name)-'"$version"'"' $metadata_file)
        new_patches=$(jq -r '.vulnerabilities[].patch_file' $metadata_file | xargs printf "$metadata_location/%s ")
        internal_patches=$(ls $metadata_location/internal-patches/*.patch 2>/dev/null || true)
        spec_patch=$(jq -r '.library_version.version_patch_file' $metadata_file | xargs printf "$metadata_location/%s ")
        source_ref_url=$(jq -r '.library_version.source_ref_url' $metadata_file)

        if [[ "$source_ref_url" != "" ]]; then
            srpm_url="$source_ref_url"
        fi

        echo "Source Reference URL:"
        echo "$source_ref_url"

        shift
        shift
        ;;

    -m | --mode)
        validate_not_set "$build_mode" "build mode"
        build_mode="$2"
        shift
        shift
        ;;

    -p | --patch)
        new_patches+="$2 "
        shift
        shift
        ;;

    -s | --spec-patch)
        validate_not_set "$spec_patch" "spec patch"
        spec_patch="$2"
        shift
        shift
        ;;

    -d | --define)
        validate_not_set "$define_flag" "define flag"
        define_flag="--define"
        define_value="$2"
        shift
        shift
        ;;

    -a | --target)
        # Since we've manually set the target to i686 when IS_OL9_32BIT is true, we can't validate_not_set
        if [[ "$IS_OL9_32BIT" != "true" ]]; then
            validate_not_set "$target" "target flag"
        fi
        target="$2"
        shift
        shift
        ;;

    -z | --zip)
        validate_not_set "$zip_output" "zip flag"
        zip_output=1
        shift
        ;;

    --baseline)
        validate_not_set "$run_baseline" "run baseline flag to run without any patches"
        run_baseline=1
        shift
        ;;

    --setup)
        setup_machine
        shift
        exit
        ;;

    -* | --*)
        echo -e "${RED}SEAL${RESET}::: invalid option $1"
        exit 1
        ;;
    *)
        echo -e "${RED}SEAL${RESET}::: invalid positional argument \"$1\""
        exit 1
        ;;
    esac
done

if [[ "$build_mode" == "" ]]; then
    # setting default here to detect it being overwritten during arg parsing
    build_mode=ba
fi

if [[ "$target" == "" ]]; then
    target=$(uname -m)
fi

echo -e "${YELLOW}SEAL${RESET}::: BUILD PARAMS:"
echo "   name:              $srpm_name"
echo "   version:           $version"
echo "   url:               $srpm_url"
echo "   mode:              $build_mode"
echo "   spec_patch:        $spec_patch"
echo "   patches:           $new_patches"
echo "   internal_patches:  $internal_patches"
echo "   define:            $define_value"
echo "   distro:            $distro"
echo "   target:            $target"
echo "   zip_output:        $zip_output"
echo "   baseline:          $run_baseline"
echo ""

######################## setup dirs ########################
echo -e "${YELLOW}SEAL${RESET}::: Checking $PWD is not in a git repo"

if git rev-parse --is-inside-work-tree &>/dev/null; then
    echo -e "${RED}SEAL${RESET}::: $PWD is in a git repo which will make apply of version patch do nothing without error! Make sure to run this script in a non-git repo"
    exit 1
fi

echo -e "${YELLOW}SEAL${RESET}::: cleaning and remaking build / log dirs"
if [ "$PWD" = "/" ]; then
    rpmbuild_dir="/rpmbuild"
else
    rpmbuild_dir="$PWD/rpmbuild"
fi
rm -rf $rpmbuild_dir
mkdir -p $rpmbuild_dir/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# dirs beside rpmbuild might have content that should not be deleted, only create if missing
#   files will be overwritten later
mkdir -p ./logs
mkdir -p ./output

### this should be run every time, even in docker
echo -e "${YELLOW}SEAL${RESET}::: setting rpm build target to $rpmbuild_dir"
if [ "$HOME" = "/" ]; then
    rpmmacros_dir="/.rpmmacros"
else
    rpmmacros_dir="$HOME/.rpmmacros"
fi
echo "%_topdir $rpmbuild_dir" >>$rpmmacros_dir

if [ "$target" = "i686" ]; then
    echo "%curr_arch x86-32" >> "$rpmmacros_dir"
else
    echo '%curr_arch %( uname -m | grep -q x86_64 && echo x86-64 || echo x86-32 )' >> "$rpmmacros_dir"
fi

######################## downloading srpm ########################
if [[ "$srpm_url" != "" ]]; then
    echo -e "${YELLOW}SEAL${RESET}::: will use url to download srpm: $srpm_url"
    if [[ "$srpm_url" == *"cdn.redhat.com"* ]]; then
        # Define certificate directories
        CERT_DIR_I386="/workdir/patching/certificates/redhat610/i386"
        CERT_DIR_X86_64="/workdir/patching/certificates/redhat610/x86_64"

        # Determine the architecture from the URL
        if [[ "$srpm_url" == *"6Server/x86_64"* ]]; then
            CERT_DIR="$CERT_DIR_X86_64"
        elif [[ "$srpm_url" == *"6Server/i386"* ]]; then
            CERT_DIR="$CERT_DIR_I386"
        else
            echo -e "${RED}SEAL${RESET}::: Unsupported architecture in URL"
            exit 1
        fi

        # Extract certificate paths
        CERT_PEM="$CERT_DIR/$(basename $CERT_DIR).pem"
        CERT_KEY="$CERT_DIR/$(basename $CERT_DIR)-key.pem"

        if [[ ! -f "$CERT_PEM" || ! -f "$CERT_KEY" ]]; then
            echo -e "${RED}SEAL${RESET}::: Missing certificates in $CERT_DIR"
            exit 1
        fi

        # Download SRPM using wget with certificates
        wget --no-check-certificate --certificate="$CERT_PEM" --private-key="$CERT_KEY" -O srpm_downloaded.rpm "$srpm_url"
    else
        wget --no-check-certificate -O srpm_downloaded.rpm "$srpm_url" # Download the SRPM using wget
    fi
    srpm=./srpm_downloaded.rpm # Point to the downloaded file
elif [[ "$srpm_name" != "" ]]; then
    srpm_name_without_epoch=$(echo $srpm_name | sed 's/[0-9]:\([0-9a-zA-Z\.]*\)/\1/')
    srpm=./$srpm_name_without_epoch.src.rpm

    echo -e "${YELLOW}SEAL${RESET}::: downloading package by name $srpm_name"
    # download target defaults to cwd
    yumdownloader --source $srpm_name
fi

if [[ "$srpm" == "" ]]; then
    echo -e "${RED}SEAL${RESET}::: no srpm"
    exit 1
fi

chmod +x $srpm # Apply chmod +x to the SRPM file
######################## install srpm ########################
echo -e "${YELLOW}SEAL${RESET}::: installing $srpm"
rpm -i $srpm &>logs/rpminstall.log

######################## build ########################
if [[ "$build_mode" == "" ]] && [[ "$spec_patch" == "" ]] && [[ "$new_patches" == "" ]]; then
    echo -e "${YELLOW}SEAL${RESET}::: installed SRPM without doing anything"
    exit
fi

# get spec path
spec=
for i in $rpmbuild_dir/SPECS/*.spec; do
    spec=$i
    break
done

# install rpm deps
echo -e "${YELLOW}SEAL${RESET}::: installing build deps for \"$spec\""
if [[ "$distro" == '"ol"' || "$distro" == '6.10' ]]; then
    if [[ "$IS_OL9_32BIT" == "true" ]]; then
        runas64 "sudo yum-builddep $spec -y" &>logs/deps.log
    else
        sudo yum-builddep $spec -y &>logs/deps.log
    fi
else
    sudo yum-builddep $spec -y &>logs/deps.log
fi

# reinstall all packages with i686 variant at the same version
if [[ "$IS_OL9_32BIT" == "true" ]]; then
    runas64 "yum list installed | grep x86_64 | awk '{split(\$1, a, \".\"); print a[1]\"-\"\$2\".i686\";}' | sudo xargs yum install -y --skip-broken"
fi

# apply spec patch (typically called version patch but for RPM spec patch because it includes other functionality)
if [[ "$spec_patch" != "" ]] && [[ "$run_baseline" != "1" ]]; then
    echo -e "${YELLOW}SEAL${RESET}::: applying spec patch from: $spec_patch"
    git apply --directory=rpmbuild $spec_patch # this adds it to the paths inside the patch, so relative to it
fi

# copy patches from collect_info to sources
if [[ "$new_patches" != "" ]] && [[ "$run_baseline" != "1" ]]; then
    echo -e "${YELLOW}SEAL${RESET}::: adding new patches: $new_patches"
    cp $new_patches $rpmbuild_dir/SOURCES/
fi

if [[ "$internal_patches" != "" ]]; then
    echo -e "${YELLOW}SEAL${RESET}::: adding internal patches: $internal_patches"
    cp $internal_patches $rpmbuild_dir/SOURCES/
fi

# build (for example, rpmbuild -ba SPECS/zlib.spec --define dist .el6_10)
echo -e "${YELLOW}SEAL${RESET}::: running rpmbuild on spec \"$spec\" using build param: $build_mode"

if [[ "$define_value" == "" ]]; then
    time rpmbuild --target $target -$build_mode $spec 2>&1 | tee logs/rpmbuild.log
else
    time rpmbuild --target $target -$build_mode $spec $define_flag "$define_value" 2>&1 | tee logs/rpmbuild.log
fi

# collect results
echo -e "${YELLOW}SEAL${RESET}::: exporting provide/require/obsolete for built packages"

# using wildcards for both noarch/$ARCH and file names
#   noarch rpms should have `noarch.rpm` suffix and therefore won't overwrite other ones
for b in $rpmbuild_dir/RPMS/*/*.rpm; do
    package_name=$(basename $b)
    echo -e "${YELLOW}SEAL${RESET}::: grabbing $b"
    package_name=$(echo $package_name | sed 's/seal-//')

    artifacts_dir=output
    build_output_dir=output
    if [ $metadata_location != "" ]; then
        artifacts_dir=$metadata_location/seal_artifacts
        build_output_dir=$metadata_location/build_output
        mkdir -p $artifacts_dir $build_output_dir
    fi

    rpm --package $b --query --provides | sort -n >$build_output_dir/$package_name.provides.txt
    rpm --package $b --query --requires | sort -n >$build_output_dir/$package_name.requires.txt
    rpm --package $b --query --obsoletes | sort -n >$build_output_dir/$package_name.obsoletes.txt
    rpm --package $b --query --list | sort -n >$build_output_dir/$package_name.files.txt
    rpm --package $b --query --conflicts | sort -n >$build_output_dir/$package_name.conflicts.txt
    mv -f $b $artifacts_dir/$package_name # overwrite previous build
done

if [[ "$zip_output" != "" ]]; then
    echo -e "${YELLOW}SEAL${RESET}::: zipping outputs"
    zip -r build.zip ./logs/ ./output/
fi

echo -e "${YELLOW}SEAL${RESET}::: done"
echo -e "   logs:   $(readlink -f ./logs)"
echo -e "   output: $(readlink -f ./output)"
if [[ "$zip_output" != "" ]]; then
    echo -e "   zipped: $(readlink -f ./build.zip)"
fi
