# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
FROM microsoft/azure-cli:latest

LABEL com.github.actions.name="Test kata-deploy on an AZ VM"
LABEL com.github.actions.description="Test kata-deploy in k3s on Azure"

# Default to latest validated AKS-engine version
ARG ARCH=amd64

ENV GITHUB_ACTION_NAME="Test kata-deploy in k3s on an AZ VM"

# When run, we expect the caller (GitHub Action workflow) to provide the
# PKG_SHA environment variable
ENV PKG_SHA=HEAD

RUN curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/${ARCH}/kubectl \
  && chmod +x ./kubectl \
  && mv ./kubectl /usr/local/bin/kubectl

COPY setup-k3s.sh test-kata.sh entrypoint.sh /

ENTRYPOINT ["/entrypoint.sh"]
