#!/bin/bash
#
# Copyright (c) 2013-2021 Igor Pecovnik, igor.pecovnik@gma**.com
#
# This file is licensed under the terms of the GNU General Public
# License version 2. This program is licensed "as is" without any
# warranty of any kind, whether express or implied.

# DO NOT EDIT THIS FILE
# use configuration files like config-default.conf to set the build configuration
# Please check Orange Pi documentation for more info
#  http://www.orangepi.cn/downloadresourcescn
#  http://www.orangepi.org/downloadresourcesexport http_proxy=http://127.0.0.1:9011/

export HTTP_PROXY=http://127.0.0.1:9011/
export https_proxy=http://127.0.0.1:9011/
export HTTPS_PROXY=http://127.0.0.1:9011/
export all_proxy=socks5://127.0.0.1:9011/
export ALL_PROXY=socks5://127.0.0.1:9011/
export no_proxy=localhost,127.0.0.0/8,::1
export NO_PROXY=localhost,127.0.0.0/8,::1
export ORANGEPI_ENABLE_CALL_TRACING=yes

SRC="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"

# check for whitespace in ${SRC} and exit for safety reasons
grep -q "[[:space:]]" <<<"${SRC}" && { echo "\"${SRC}\" contains whitespace. Not supported. Aborting." >&2 ; exit 1 ; }

cd "${SRC}" || exit

if [[ "${ORANGEPI_ENABLE_CALL_TRACING}" == "yes" ]]; then
	set -T # inherit return/debug traps
	mkdir -p "${SRC}"/output/debug
	echo -n "" > "${SRC}"/output/debug/calls.txt
	trap 'echo "${BASH_LINENO[@]}|${BASH_SOURCE[@]}|${FUNCNAME[@]}" >> ${SRC}/output/debug/calls.txt ;' RETURN
fi

if [[ -f "${SRC}"/scripts/general.sh ]]; then

	# shellcheck source=scripts/general.sh
	source "${SRC}"/scripts/general.sh

else

	echo "Error: missing build directory structure"
	echo "Please clone the full repository by https://github.com/orangepi-xunlong/orangepi-build"
	exit 255

fi

#  Add the variables needed at the beginning of the path
check_args ()
{

for p in "$@"; do

	case "${p%=*}" in
		LIB_TAG)
			# Take a variable if the branch exists locally
			if [ "${p#*=}" == "$(git branch | \
				gawk -v b="${p#*=}" '{if ( $NF == b ) {print $NF}}')" ]; then
				echo -e "[\e[0;35m warn \x1B[0m] Setting $p"
				eval "$p"
			else
				echo -e "[\e[0;35m warn \x1B[0m] Skip $p setting as LIB_TAG=\"\""
				eval LIB_TAG=""
			fi
			;;
	esac

done

}


check_args "$@"


update_src() {

	cd "${SRC}" || exit
	if [[ ! -f "${SRC}"/.ignore_changes ]]; then
		echo -e "[\e[0;32m o.k. \x1B[0m] This script will try to update"

		CHANGED_FILES=$(git diff --name-only)
		if [[ -n "${CHANGED_FILES}" ]]; then
			echo -e "[\e[0;35m warn \x1B[0m] Can't update since you made changes to: \e[0;32m\n${CHANGED_FILES}\x1B[0m"
			while true; do
				echo -e "Press \e[0;33m<Ctrl-C>\x1B[0m or \e[0;33mexit\x1B[0m to abort compilation"\
				", \e[0;33m<Enter>\x1B[0m to ignore and continue, \e[0;33mdiff\x1B[0m to display changes"
				read -r
				if [[ "${REPLY}" == "diff" ]]; then
					git diff
				elif [[ "${REPLY}" == "exit" ]]; then
					exit 1
				elif [[ "${REPLY}" == "" ]]; then
					break
				else
					echo "Unknown command!"
				fi
			done
		elif [[ $(git branch | grep "*" | awk '{print $2}') != "${LIB_TAG}" && -n "${LIB_TAG}" ]]; then
			git checkout "${LIB_TAG:-master}"
			git pull
		fi
	fi

}


TMPFILE=$(mktemp)
chmod 644 "${TMPFILE}"
{

	echo SRC="$SRC"
	echo LIB_TAG="$LIB_TAG"
	declare -f update_src
	#echo "update_src"

}  > "$TMPFILE"

#do not update/checkout git with root privileges to messup files onwership.
#due to in docker/VM, we can't su to a normal user, so do not update/checkout git.
if [[ $(systemd-detect-virt) == 'none' ]]; then

	if [[ "${EUID}" == "0" ]]; then
		su "$(stat --format=%U "${SRC}"/.git)" -c "bash ${TMPFILE}"
	else
		bash "${TMPFILE}"
	fi

fi


rm "${TMPFILE}"


if [[ "${EUID}" == "0" ]] || [[ "${1}" == "vagrant" ]]; then
	:
elif [[ "${1}" == docker || "${1}" == dockerpurge || "${1}" == docker-shell ]] && grep -q "$(whoami)" <(getent group docker); then
	:
else
	display_alert "This script requires root privileges, trying to use sudo" "" "wrn"
	sudo "${SRC}/build.sh" "$@"
	exit $?
fi

if [ "$OFFLINE_WORK" == "yes" ]; then

	echo -e "\n"
	display_alert "* " "You are working offline."
	display_alert "* " "Sources, time and host will not be checked"
	echo -e "\n"
	sleep 3s

else

	# check and install the basic utilities here
	prepare_host_basic

fi

# Check for Vagrant
if [[ "${1}" == vagrant && -z "$(command -v vagrant)" ]]; then
	display_alert "Vagrant not installed." "Installing"
	sudo apt-get update
	sudo apt-get install -y vagrant virtualbox
fi

# Purge Orange Pi Docker images
if [[ "${1}" == dockerpurge && -f /etc/debian_version ]]; then
	display_alert "Purging Orange Pi Docker containers" "" "wrn"
	docker container ls -a | grep orangepi | awk '{print $1}' | xargs docker container rm &> /dev/null
	docker image ls | grep orangepi | awk '{print $3}' | xargs docker image rm &> /dev/null
	shift
	set -- "docker" "$@"
fi

# Docker shell
if [[ "${1}" == docker-shell ]]; then
	shift
	#shellcheck disable=SC2034
	SHELL_ONLY=yes
	set -- "docker" "$@"
fi

# Install Docker if not there but wanted. We cover only Debian based distro install. On other distros, manual Docker install is needed
if [[ "${1}" == docker && -f /etc/debian_version && -z "$(command -v docker)" ]]; then

	DOCKER_BINARY="docker-ce"

	# add exception for Ubuntu Focal until Docker provides dedicated binary
	codename=$(cat /etc/os-release | grep VERSION_CODENAME | cut -d"=" -f2)
	codeid=$(cat /etc/os-release | grep ^NAME | cut -d"=" -f2 | awk '{print tolower($0)}' | tr -d '"' | awk '{print $1}')
	[[ "${codename}" == "debbie" ]] && codename="buster" && codeid="debian"
	[[ "${codename}" == "ulyana" || "${codename}" == "jammy" ]] && codename="focal" && codeid="ubuntu"

	# different binaries for some. TBD. Need to check for all others
	[[ "${codename}" =~ focal|hirsute ]] && DOCKER_BINARY="docker containerd docker.io"

	display_alert "Docker not installed." "Installing" "Info"
	sudo bash -c "echo \"deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/${codeid} ${codename} stable\" > /etc/apt/sources.list.d/docker.list"

	sudo bash -c "curl -fsSL \"https://download.docker.com/linux/${codeid}/gpg\" | apt-key add -qq - > /dev/null 2>&1 "
	export DEBIAN_FRONTEND=noninteractive
	sudo apt-get update
	sudo apt-get install -y -qq --no-install-recommends ${DOCKER_BINARY}
	display_alert "Add yourself to docker group to avoid root privileges" "" "wrn"
	"${SRC}/build.sh" "$@"
	exit $?

fi

EXTER="${SRC}/external"

# Create userpatches directory if not exists
mkdir -p "${SRC}"/userpatches


# Create example configs if none found in userpatches
if ! ls "${SRC}"/userpatches/{config-example.conf,config-docker.conf,config-vagrant.conf} 1> /dev/null 2>&1; then

	# Migrate old configs
	if ls "${SRC}"/*.conf 1> /dev/null 2>&1; then
		display_alert "Migrate config files to userpatches directory" "all *.conf" "info"
                cp "${SRC}"/*.conf "${SRC}"/userpatches  || exit 1
		rm "${SRC}"/*.conf
		[[ ! -L "${SRC}"/userpatches/config-example.conf ]] && ln -fs config-example.conf "${SRC}"/userpatches/config-default.conf || exit 1
	fi

	display_alert "Create example config file using template" "config-default.conf" "info"

	# Create example config
	if [[ ! -f "${SRC}"/userpatches/config-example.conf ]]; then
		cp "${EXTER}"/config/templates/config-example.conf "${SRC}"/userpatches/config-example.conf || exit 1
                ln -fs config-example.conf "${SRC}"/userpatches/config-default.conf || exit 1
	fi

	# Create Docker config
	if [[ ! -f "${SRC}"/userpatches/config-docker.conf ]]; then
		cp "${EXTER}"/config/templates/config-docker.conf "${SRC}"/userpatches/config-docker.conf || exit 1
	fi

	# Create Docker file
        if [[ ! -f "${SRC}"/userpatches/Dockerfile ]]; then
                cp "${EXTER}"/config/templates/Dockerfile "${SRC}"/userpatches/Dockerfile || exit 1
        fi

	# Create Vagrant config
	if [[ ! -f "${SRC}"/userpatches/config-vagrant.conf ]]; then
	        cp "${EXTER}"/config/templates/config-vagrant.conf "${SRC}"/userpatches/config-vagrant.conf || exit 1
	fi

	# Create Vagrant file
	if [[ ! -f "${SRC}"/userpatches/Vagrantfile ]]; then
		cp "${EXTER}"/config/templates/Vagrantfile "${SRC}"/userpatches/Vagrantfile || exit 1
	fi

fi

if [[ -z "${CONFIG}" && -n "$1" && -f "${SRC}/userpatches/config-$1.conf" ]]; then
	CONFIG="userpatches/config-$1.conf"
	shift
fi

# usind default if custom not found
if [[ -z "${CONFIG}" && -f "${SRC}/userpatches/config-default.conf" ]]; then
	CONFIG="userpatches/config-default.conf"
fi

# source build configuration file
CONFIG_FILE="$(realpath "${CONFIG}")"

if [[ ! -f "${CONFIG_FILE}" ]]; then
	display_alert "Config file does not exist" "${CONFIG}" "error"
	exit 254
fi

CONFIG_PATH=$(dirname "${CONFIG_FILE}")

# Source the extensions manager library at this point, before sourcing the config.
# This allows early calls to enable_extension(), but initialization proper is done later.
# shellcheck source=scripts/extensions.sh
source "${SRC}"/scripts/extensions.sh

display_alert "Using config file" "${CONFIG_FILE}" "info"
pushd "${CONFIG_PATH}" > /dev/null || exit
# shellcheck source=/dev/null
source "${CONFIG_FILE}"
popd > /dev/null || exit

[[ -z "${USERPATCHES_PATH}" ]] && USERPATCHES_PATH="${CONFIG_PATH}"

# Script parameters handling
while [[ "${1}" == *=* ]]; do

	parameter=${1%%=*}
	value=${1##*=}
	shift
	display_alert "Command line: setting $parameter to" "${value:-(empty)}" "info"
	eval "$parameter=\"$value\""

done


if [[ "${BUILD_ALL}" == "yes" || "${BUILD_ALL}" == "demo" ]]; then

	# shellcheck source=scripts/build-all-ng.sh
	source "${SRC}"/scripts/build-all-ng.sh

else

	# shellcheck source=scripts/main.sh
	source "${SRC}"/scripts/main.sh

fi
