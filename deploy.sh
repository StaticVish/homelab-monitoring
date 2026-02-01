#!/bin/bash
set -e

# Check if key.txt exists
if [ ! -f "key.txt" ]; then
    echo "Error: key.txt not found! You need the age private key to deploy."
    exit 1
fi

export SOPS_AGE_KEY_FILE=$(pwd)/key.txt

echo "Ensuring namespace exists..."
sudo k3s kubectl create namespace monitoring --dry-run=client -o yaml | sudo k3s kubectl apply -f -

echo "Applying Secrets..."
sops --decrypt k8s/overlays/prod/secrets/alertmanager-secret.enc.yaml | sudo k3s kubectl apply -f -

echo "Applying Monitoring Stack..."
# Using kustomize to build the manifests (including the HelmChart CRD)
kustomize build k8s/overlays/prod | sudo k3s kubectl apply --server-side -f -

echo "Deployment Complete."
