#!/bin/bash

source ../provision-scripts/_provision-scripts.lib 2>/dev/null || true

CREDS_FILE="../gen/workshop-credentials.json"
if [ -f "$CREDS_FILE" ]; then
    AZURE_RESOURCE_GROUP=$(cat "$CREDS_FILE" | jq -r '.AZURE_RESOURCE_GROUP // empty')
    AZURE_AKS_CLUSTER_NAME=$(cat "$CREDS_FILE" | jq -r '.AZURE_AKS_CLUSTER_NAME // empty')
fi

AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP:-"dynatrace-azure-workshop"}
AZURE_AKS_CLUSTER_NAME=${AZURE_AKS_CLUSTER_NAME:-"dynatrace-azure-workshop-cluster"}

echo "Restarting Travel Advisor..."
az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing &>/dev/null

if kubectl -n travel-advisor-azure-openai-sample rollout restart deployment; then
    echo "Done. Pods are restarting."
    echo ""
    echo "Check status: kubectl -n travel-advisor-azure-openai-sample get pods"
else
    echo "ERROR: Failed to restart. Check if namespace exists."
fi
