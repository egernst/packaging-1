#!/bin/bash
#
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o pipefail
set -o nounset

function die() {
    msg="$*"
    echo "ERROR: $msg" >&2
    exit 1
}

function waitForProcess() {
    wait_time="$1"
    cmd="$2"
    sleep_time=5
    while [ "$wait_time" -gt 0 ]; do
        if eval "$cmd"; then
            return 0
        else
            echo "waiting"
            sleep "$sleep_time"
            wait_time=$((wait_time-sleep_time))
        fi
    done
    die "wait for $cmd timed out"
}

# waitForLabelRemoval will wait for the kata-runtime labels to removed until a given
# timeout expires
function waitForLabelRemoval() {
    wait_time="$1"
    sleep_time=5

    echo "waiting for kata-runtime label to be removed"
    while [[ "$wait_time" -gt 0 ]]; do
        # if a node is found which matches node-select, the output will include a column for node name,
        # NAME. Let's look for that 
        if [[ -z $(kubectl get --request-timeout='30s' nodes --selector katacontainers.io/kata-runtime | grep NAME) ]]
        then
            return 0
        else
            sleep "$sleep_time"
            wait_time=$((wait_time-sleep_time))
        fi
    done

    echo $(kubectl get --request-timeout='30s' nodes --show-labels)
    die "failed to cleanup"
}

function myKubectlWait() {
  wait_time="$1"
  wait_cmd="$2"
  sleep_time=5

  echo "waiting for $2"
  while [[ "$wait_time" -gt 0 ]]; do
    if [[   $(kubectl wait --timeout=0 $wait_cmd) ]]; then
      echo "condition met"
      return 0
    else
      sleep "$sleep_time"
      wait_time=$((wait_time-sleep_time))
    fi 
  done

  die "wait for $2 failed"
}

function run_test() {
    YAMLPATH="./kata-deploy"

    echo "verify connectivity with a pod using Kata"

    deployment=""
    busybox_pod="test-nginx"
    busybox_image="busybox"
    cmd="kubectl --request-timeout='30s' get pods | grep $busybox_pod | grep Completed"
    wait_time=120
    sleep_time=3

    configurations=("nginx-deployment-qemu" "nginx-deployment-qemu-virtiofs")
    for deployment in "${configurations[@]}"; do
      # start the kata pod:
      kubectl apply -f "$YAMLPATH/examples/${deployment}.yaml"

      # in case the control plane is slow, give it a few seconds to accept the yaml, otherwise
      # our 'wait' for deployment status will fail to find the deployment at all
      sleep 3 

      myKubectlWait 600 "--for=condition=Available deployment/${deployment}"
      kubectl expose deployment/${deployment}

      # test pod connectivity:
      kubectl run $busybox_pod --restart=Never --image="$busybox_image" -- wget --timeout=5 "$deployment"
      waitForProcess "$wait_time" "$cmd"
      kubectl logs --request-timeout='30s' "$busybox_pod" | grep "index.html"
      kubectl describe --request-timeout='30s'  pod "$busybox_pod"

      # cleanup:
      kubectl delete deployment "$deployment"
      kubectl delete service "$deployment"
      kubectl delete pod "$busybox_pod"
  done
}


function test_kata() {
    set -x

    echo $(ls)
    echo $(pwd)

    [[ -z "$PKG_SHA" ]] && die "no PKG_SHA provided"
    echo "$PKG_SHA"

    #kubectl all the things
    kubectl get --request-timeout='30s' pods,nodes --all-namespaces

    YAMLPATH="./kata-deploy"
    kubectl apply -f "$YAMLPATH/kata-rbac/base/kata-rbac.yaml"

    # apply runtime classes:
    kubectl apply -f "$YAMLPATH/k8s-1.14/kata-qemu-runtimeClass.yaml"
    kubectl apply -f "$YAMLPATH/k8s-1.14/kata-qemu-virtiofs-runtimeClass.yaml"

    kubectl get --request-timeout='30s' runtimeclasses

    # update deployment daemonset to utilize the container under test:
    sed -i "s#katadocker/kata-deploy#katadocker/kata-deploy-ci:${PKG_SHA}#g" $YAMLPATH/kata-deploy/base/kata-deploy.yaml
    sed -i "s#katadocker/kata-deploy#katadocker/kata-deploy-ci:${PKG_SHA}#g" $YAMLPATH/kata-cleanup/base/kata-cleanup.yaml

    cat $YAMLPATH/kata-deploy/base/kata-deploy.yaml

    # deploy kata:
    kubectl apply -k $YAMLPATH/kata-deploy/overlays/k3s

    # in case the control plane is slow, give it a few seconds to accept the yaml, otherwise
    # our 'wait' for deployment status will fail to find the deployment at all. If it can't persist
    # the daemonset to etcd in 30 seconds... then we'll fail.
    sleep 30

    # wait for kata-deploy to be up
    myKubectlWait 600 "-n kube-system --for=condition=Ready -l name=kata-deploy pod"

    # show running pods, and labels of nodes
    kubectl get --request-timeout='30s' pods,nodes --all-namespaces --show-labels

    run_test

    kubectl get --request-timeout='30s' pods,nodes --show-labels

    # Remove Kata
    kubectl delete -k $YAMLPATH/kata-deploy/overlays/k3s

    # wait for kata-deploy pod to be deleted; waiting for 10 minutes 
    #kubectl -n kube-system wait --timeout=10m --for=delete -l name=kata-deploy pod
    start=$(date +%s); now=$start
    echo "wait for kata-deploy deletion"
    until [[ ! $(kubectl get --ignore-not-found=true daemonset -n kube-system kata-deploy 2>&1) ]]; do 
      sleep 2;
      now=$(date +%s)
      if [ $((now-start)) -gt 600 ]; then
        die "timeout waiting for kata-deploy to delete"
      fi 
    done

    kubectl get --request-timeout='30s' pods,nodes --show-labels

    kubectl apply -f $YAMLPATH/kata-cleanup/base/kata-cleanup.yaml

    # The cleanup daemonset will run a single time, since it will clear the node-label. Thus, its difficult to
    # check the daemonset's status for completion. instead, let's wait until the kata-runtime labels are removed
    # from all of the worker nodes. If this doesn't happen after 2 minutes, let's fail
    timeout=120
    waitForLabelRemoval $timeout

    kubectl delete -f $YAMLPATH/kata-cleanup/base/kata-cleanup.yaml

    rm kata-cleanup.yaml
    rm kata-deploy.yaml

    set +x
}
