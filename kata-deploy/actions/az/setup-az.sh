#!/bin/bash
#
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
set -o errexit
set -o pipefail
set -o nounset

#### HORRIBLE: LOCAL SECRET: DELETE PLS #####
export AZ_APPID=961b1180-855f-4433-becc-16ec843c7579
export AZ_PASSWORD=487316dc-a838-4941-b7f8-ac28b6a00955
export AZ_SUBSCRIPTION_ID=2efae366-54ff-4d92-b51e-7454e50408e3
export AZ_TENANT_ID=bda2b831-bb6b-41a2-b562-fc7ab1b8bd07

LOCATION=${LOCATION:-westus2}
#DNS_PREFIX=${DNS_PREFIX:-kata-deploy-${GITHUB_SHA:0:10}}
DNS_PREFIX="test-kata-2"

function die() {
    msg="$*"
    echo "ERROR: $msg" >&2
    exit 1
}

function destroy_vm() {
	set +x

	az login --service-principal -u "$AZ_APPID" -p "$AZ_PASSWORD" --tenant "$AZ_TENANT_ID"
	az group delete --name "$DNS_PREFIX" --yes --no-wait
	az logout
}


#
# Create the virtual machine
#
function setup_az_k8s_master() {
	[[ -z "$AZ_APPID" ]] && die "no Azure service principal ID provided"
	[[ -z "$AZ_PASSWORD" ]] && die "no Azure service principal secret provided"
	[[ -z "$AZ_SUBSCRIPTION_ID" ]] && die "no Azure subscription ID provided"
	[[ -z "$AZ_TENANT_ID" ]] && die "no Azure tenant ID provided"

	# Create the virtual machine:
	az group create --name ${DNS_PREFIX} --location ${LOCATION}
	result=$(az vm create \
		--resource-group ${DNS_PREFIX} \
		--size Standard_D4S_v3 \
		--os-disk-size-gb 40 \
		--name ${DNS_PREFIX}-vm \
		--image UbuntuLTS \
		--admin-username kata \
		--generate-ssh-keys )

	publicIP=$(echo $result | jq -r '.publicIpAddress')

	echo $result
	echo $publicIP

	# Install Kubernetes, containerd on the VM:
	ssh-keyscan ${publicIP} >> ~/.ssh/known_hosts
	ssh kata@${publicIP} "wget https://raw.githubusercontent.com/egernst/k8s-pod-overhead/master/node-setup/install-prereqs.sh -O - | sh -" || true
	ssh kata@${publicIP} "wget https://raw.githubusercontent.com/egernst/k8s-pod-overhead/master/node-setup/containerd_devmapper_setup.sh -O - | sh -" || true
	ssh kata@${publicIP} "wget https://raw.githubusercontent.com/egernst/k8s-pod-overhead/master/kubeadm.yaml" || 1

	# Start the cluster, and setup port-forward so we can access from the VM's public IP (will forward to 8001 in the VM)
	ssh kata@${publicIP} "wget https://raw.githubusercontent.com/egernst/k8s-pod-overhead/master/create_stack.sh -O - | sh -" || true
	ssh kata@${publicIP} "nohup kubectl proxy &> /dev/null </dev/null &" || true

	# Grab the kube-config:
	scp kata@{publicIP}:/home/kata/.kube/config . || true
	export KUBECONFIG=./config

	# port forward locally so we can access the API-server:
	ssh -nNT -L 8001:localhost:8001 kata@${publicIP} & 

	# Edit the kube-conf so kubectl will talk to api-server via the forwarded
	# port, local
	sed -i s/server:.*$/server:\ localhost:8001/ config

	# wait for the cluster to be settled:
	kubectl wait --timeout=10m --for=condition=Ready --all nodes

	# make sure coredns is up before moving forward:
	kubectl wait --timeout=10m -n kube-system --for=condition=Available deployment.extensions/coredns
}
