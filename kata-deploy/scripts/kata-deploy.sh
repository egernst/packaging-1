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
	echo "Usage: $0 [install/cleanup/reset]"
}

function get_container_runtime() {
	local runtime=$(kubectl describe node $NODE_NAME)
	if [ "$?" -ne 0 ]; then
                die "invalid node name"
	fi
	echo "$runtime" | awk -F'[:]' '/Container Runtime Version/ {print $2}' | tr -d ' '
}

function install_artifacts() {
	echo "copying kata artifacts onto host"
	cp -a /opt/kata-artifacts/opt/kata/* /opt/kata/
	chmod +x /opt/kata/bin/*
}

function configure_runtime() {
	echo "Add Kata Containers as a supported runtime:"
	case $1 in
	crio)
		configure_crio
		;;
	containerd)
		configure_containerd
		;;

	docker)
		configure_docker
		;;
	esac
	systemctl daemon-reload
	systemctl restart $1
}

function configure_crio() {
	# Configure crio to use Kata:
	echo "Add Kata Containers as a supported runtime:"


	# backup the CRIO.conf only if a backup doesn't already exist (don't override original)
	conf_file="/etc/crio/crio.conf"
	backup_conf_file="${conf_file}.bak"
	cp -n "$conf_file" "$backup_conf_file"

	cat <<EOT | tee -a "$conf_file"
[crio.runtime.runtimes.kata-qemu]
  runtime_path = "/opt/kata/bin/kata-qemu"
[crio.runtime.runtimes.kata-fc]
  runtime_path = "/opt/kata/bin/kata-fc"
EOT

	sed -i 's|\(\[crio\.runtime\]\)|\1\nmanage_network_ns_lifecycle = true|' "$conf_file"
}

function configure_containerd() {
	# Configure containerd to use Kata:
	echo "create containerd configuration for Kata"
	mkdir -p /etc/containerd/

	if [ -f /etc/containerd/config.toml ]; then
		cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
	fi
	# TODO: While there isn't a default here anyway, it'd probably be best to
	#  add sed magic to insert into appropriate location if config.toml already exists
	# https://github.com/kata-containers/packaging/issues/307
	cat <<EOT | tee /etc/containerd/config.toml
[plugins]
    [plugins.cri.containerd]
      [plugins.cri.containerd.untrusted_workload_runtime]
        runtime_type = "io.containerd.runtime.v1.linux"
        runtime_engine = "/opt/kata/bin/kata-runtime"
        runtime_root = ""
EOT
}

function configure_docker() {
	echo "configuring docker"
}

function remove_artifacts() {
	echo "deleting kata artifacts"
	rm -rf /opt/kata/
}

function cleanup_runtime() {
	case $1 in
	crio)
		cleanup_crio
		;;
	containerd)
		cleanup_containerd
		;;
	docker)
		cleanup_docker
		;;
	esac

}

function cleanup_crio() {
	if [ -f /etc/crio/crio.conf.bak ]; then
		mv /etc/crio/crio.conf.bak /etc/crio/crio.conf
	fi
}

function cleanup_containerd() {
	rm -f /etc/containerd/config.toml
	if [ -f /etc/containerd/config.toml.bak ]; then
		mv /etc/containerd/config.toml.bak /etc/containerd/config.toml
	fi

}

function cleanup_docker() {
	echo "cleanup docker"
}

function main() {

	# script requires that user is root
	euid=`id -u`
	if [[ $euid -ne 0 ]]; then
	   die  "This script must be run as root"
	fi

	configureDocker="false"
	while getopts "d" opt; do
		case "$opt" in
		d)
			configureDocker="true"
			shift $((OPTIND - 1))
			;;
		esac
	done

	action=${1:-}
	if [ -z $action ]; then 
		print_usage
		die "invalid arguments"	
	fi	


	if [ $configureDocker == "true" ] ; then
		runtime="docker"
	else
		runtime=$(get_container_runtime)
	fi		

	echo configureDocker: $configureDocker

	# only install / remove / update if we are dealing with CRIO or containerd
	if [ "$runtime" == "cri-o" ] || [ "$runtime" == "containerd" ] || [ "$runtime" == "docker" ] ; then

		case $1 in
		install)

			install_artifacts
			configure_runtime $runtime
			;;
		cleanup)
			remove_artifacts
			cleanup_runtime $runtime
			if [ $configureDocker == "false" ]; then
				kubectl label node $NODE_NAME --overwrite kata-containers.io/kata-runtime=cleanup
			fi
			;;
		reset)

			if [ $configureDocker == "false" ]; then
				kubectl label node $NODE_NAME kata-containers.io/container-runtime- kata-containers.io/kata-runtime-
			else
				echo "resetting for docker"
			fi
			systemctl daemon-reload
			systemctl restart $runtime
			;;
		*)
			echo invalid arguments
			print_usage
			;;
		esac
	fi

	#It is assumed this script will be called as a daemonset. As a result, do
        # not return, otherwise the daemon will restart and rexecute the script
	if [ $configureDocker == "false" ]; then
		sleep infinity
	fi
}

main $@
