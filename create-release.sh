#!/bin/bash -xe

oc adm release new -n origin --from-release registry.ci.openshift.org/ocp/release:4.11.0-0.ci-2022-06-23-165527 \
                             --to-image quay.io/ellorent/origin-release:v4.11 \
                             machine-config-operator=quay.io/ellorent/machine-config-operator@sha256:623539e370a1ac4af30d3ee62ff685d8802656d8f63469a17f5ad36fdbc07799 \
			     machine-os-content=quay.io/ellorent/ocp-4.11-nmstate@sha256:b3feecfe1aaee03a8964e955a6a53d639cdcd089f89054c3e1eb669bbbfbc1cb
