#!/usr/bin/env bash
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o pipefail
set -o nounset


# If we fail for any reason a message will be displayed
die() {
        msg="$*"
        echo "ERROR: $msg" >&2
        exit 1
}

function print_usage() {
	echo "Usage: $0 [install/remove]"
}

function install_artifacts() {
	echo "copying kata artifacts onto host"
	cp -a /opt/kata-artifacts/opt/kata/* /opt/kata/
	chmod +x /opt/kata/bin/*
}

function version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

function configure_docker() {
	echo "configuring docker"


	local storage_driver=$(docker info --format '{{json .Driver}}')
	if [ $storage_driver == "devicemapper" ]; then
		echo "WARNING: devicemapper not configured. Firecracker configuration of kata, kata-fc, will not work"
	fi
	
	local docker_version=$(docker info --format '{{json .ServerVersion}}')
	echo "docker version $docker_version installed; 18.06 is the latest version that supports devicemapper"


	if [ -f /etc/docker/daemon.json ]; then
		cp /etc/docker/daemon.json /etc/docker/daemon.json.bak
	fi

	tmp=$(jq '.runtimes."kata-qemu"' /etc/docker/daemon.json)
	if ! [ $tmp == "" ]; then
		echo "WARNING: prior install of kata-qemu existed: overwriting!!" 
	fi	

	tmp=$(jq '.runtimes."kata-fc"' /etc/docker/daemon.json)
	if ! [ $tmp == "" ]; then
		echo "WARNING: prior install of kata-fc existed: overwriting!!" 
	fi


	cat <<EOT | tee -a /etc/docker/daemon.json.tmp
{
  "runtimes": {
    "kata-qemu": {
      "path": "/opt/kata/bin/kata-qemu"
    },
     "kata-fc": {
      "path": "/opt/kata/bin/kata-fc"
    }
}
EOT
	jq -s '[.[] | to_entries] | flatten | reduce .[] as $dot ({}; .[$dot.key] += $dot.value)' /etc/docker/daemon.json /etc/docker/daemon.json.tmp

	systemctl daemon-reload
	systemctl reload docker
}

function remove_artifacts() {
	echo "deleting kata artifacts"
	rm -rf /opt/kata/
}

function cleanup_runtime() {
	echo "cleanup docker"
	systemctl daemon-reload
	systemctl reload docker
}

function main() {
	# script requires that user is root
	euid=`id -u`
	if [[ $euid -ne 0 ]]; then
	   die  "This script must be run as root"
	fi

	action=${1:-}
	if [ -z $action ]; then 
		print_usage
		die "invalid arguments"	
	fi	

		case $action in
		install)
#			install_artifacts
			configure_docker
			;;
		remove)
			remove_artifacts
			cleanup_runtime
			systemctl daemon-reload
			systemctl reload docker
			;;
		*)
			echo invalid arguments
			print_usage
			;;
		esac
}

main $@
