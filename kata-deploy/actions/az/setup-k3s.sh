#!/bin/bash
#
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
set -o errexit
set -o pipefail
set -o nounset

LOCATION=${LOCATION:-westus2}
DNS_PREFIX=${DNS_PREFIX:-kata-deploy-${GITHUB_SHA:0:10}}

function die() {
	msg="$*"
	echo "ERROR: $msg" >&2
	exit 1
}

function destroy_k3s() {
	set +x

	az login --service-principal -u "$AZ_APPID" -p "$AZ_PASSWORD" --tenant "$AZ_TENANT_ID"
	az group delete --name "$DNS_PREFIX" --yes --no-wait
	az logout
}

function setup_k3s() {
	set +x

	[[ -z "$AZ_APPID" ]] && die "no Azure service principal ID provided"
	[[ -z "$AZ_PASSWORD" ]] && die "no Azure service principal secret provided"
	[[ -z "$AZ_SUBSCRIPTION_ID" ]] && die "no Azure subscription ID provided"
	[[ -z "$AZ_TENANT_ID" ]] && die "no Azure tenant ID provided"

	# Create the virtual machine:
	az login --service-principal -u "$AZ_APPID" -p "$AZ_PASSWORD" --tenant "$AZ_TENANT_ID"

	# create resource group
	az group create --name ${DNS_PREFIX} --location ${LOCATION}

	# setup security groups for inbound:
	az network nsg create --resource-group ${DNS_PREFIX} --name k3s-nsg
	az network nsg rule create --name ssh-access --nsg-name k3s-nsg --resource-group ${DNS_PREFIX} --priority 100 --access Allow --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 22 --protocol Tcp
	az network nsg rule create --name access-api-server --nsg-name k3s-nsg --resource-group ${DNS_PREFIX} --priority 101 --access Allow --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges 6443 --protocol Tcp

	# create key for the nodes. In GHActions, we cannot modify default keys (~/.ssh/), so we need to generate
	# our own at an acceptable location
	KEY_PATH=/tmp/id_rsa
	ssh-keygen -f ${KEY_PATH} -t rsa -N ''

	result=$(az vm create \
		--resource-group ${DNS_PREFIX} \
		--size Standard_D4S_v3 \
		--name ${DNS_PREFIX}-master \
		--image UbuntuLTS \
		--nsg k3s-nsg \
		--admin-username kata \
		--ssh-key-values ${KEY_PATH}.pub )
	masterIP=$(echo $result | jq -r '.publicIpAddress')

	result=$(az vm create \
		--resource-group ${DNS_PREFIX} \
		--size Standard_D4S_v3 \
		--name ${DNS_PREFIX}-worker \
		--image UbuntuLTS \
		--nsg k3s-nsg \
		--admin-username kata \
		--ssh-key-values ${KEY_PATH}.pub )
	workerIP=$(echo $result | jq -r '.publicIpAddress')

	set -x

	echo master, worker: ${masterIP} ${workerIP}

	# Setup K3s on master:

	#james, don't look at this next line:
	curl -sLS https://raw.githubusercontent.com/alexellis/k3sup/master/get.sh | sh
	k3sup  install --ip $masterIP --user kata --ssh-key ${KEY_PATH}
	k3sup join --ip ${workerIP} --server-ip ${masterIP} --user kata --ssh-key ${KEY_PATH}

	export KUBECONFIG=$PWD/kubeconfig
}
