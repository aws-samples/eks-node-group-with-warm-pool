#!/bin/bash

helm repo add autoscaler "https://kubernetes.github.io/autoscaler"
helm repo update
helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
    --namespace kube-system \
    --set awsRegion=us-west-2 \
    --set cloudProvider=aws \
    --set image.repository="registry.k8s.io/autoscaling/cluster-autoscaler" \
    --set image.tag="v1.27.5" \
    --set autoDiscovery.clusterName=example \
    --set extraArgs.skip-nodes-with-system-pods=false \
    --set extraArgs.scale-down-delay-after-delete=2m \
    --set rbac.serviceAccount.annotations."eks\.amazonaws\.com/role-arn=arn:aws:iam::875314935082:role/exampleClusterAutoscaler" \
    --set rbac.serviceAccount.name=cluster-autoscaler \
    --set podAnnotations."cluster\.autoscaler\.kubernetes\.io/safe-to-evict='false'" \
    --set extraEnv."AWS_DEFAULT_REGION=us-west-2" \
    --set extraEnv."AWS_STS_REGIONAL_ENDPOINTS=regional" \
    --set extraVolumeMounts[0].name=ssl-certs \
    --set extraVolumeMounts[0].mountPath="/etc/ssl/certs/ca-certificates.crt" \
    --set extraVolumeMounts[0].readOnly=true \
    --set extraVolumes[0].name=ssl-certs \
    --set extraVolumes[0].hostPath.path="/etc/ssl/certs/ca-bundle.crt"
