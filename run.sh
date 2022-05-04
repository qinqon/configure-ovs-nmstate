#!/bin/bash -xe

kcli delete -y plan configure-ovs || true
kcli create plan -f plan.yaml configure-ovs
