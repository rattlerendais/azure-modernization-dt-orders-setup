#!/bin/bash

source ../provision-scripts/_provision-scripts.lib 2>/dev/null || true

# Load credentials from workshop-credentials.json if available
CREDS_FILE="../gen/workshop-credentials.json"
if [ -f "$CREDS_FILE" ]; then
    AZURE_RESOURCE_GROUP=$(cat "$CREDS_FILE" | jq -r '.AZURE_RESOURCE_GROUP // empty')
    AZURE_AKS_CLUSTER_NAME=$(cat "$CREDS_FILE" | jq -r '.AZURE_AKS_CLUSTER_NAME // empty')
fi

# Use defaults if not set
AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP:-"dynatrace-azure-workshop"}
AZURE_AKS_CLUSTER_NAME=${AZURE_AKS_CLUSTER_NAME:-"dynatrace-azure-workshop-cluster"}

echo "=========================================================="
echo "Restarting K8s Apps"
echo "=========================================================="
echo "  Resource Group: $AZURE_RESOURCE_GROUP"
echo "  AKS Cluster:    $AZURE_AKS_CLUSTER_NAME"
echo ""

# Get AKS credentials
if ! az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing &>/dev/null; then
    echo "ERROR: Failed to get AKS credentials."
    exit 1
fi

# Verify connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster."
    exit 1
fi
echo "  Connected successfully."
echo ""

# ==========================================================
# Restart DT Orders
# ==========================================================
echo "Restarting DT Orders (namespace: staging)..."
if kubectl -n staging rollout restart deployment 2>/dev/null; then
    echo "  Done."
else
    echo "  WARNING: No deployments found or namespace doesn't exist"
fi

# ==========================================================
# Restart Travel Advisor
# ==========================================================
echo "Restarting Travel Advisor (namespace: travel-advisor-azure-openai-sample)..."
if kubectl -n travel-advisor-azure-openai-sample rollout restart deployment 2>/dev/null; then
    echo "  Done."
else
    echo "  WARNING: No deployments found or namespace doesn't exist"
fi

echo ""
echo "=========================================================="
echo "Restart Complete!"
echo "=========================================================="
echo ""
echo "Check pod status with:"
echo "  kubectl -n staging get pods"
echo "  kubectl -n travel-advisor-azure-openai-sample get pods"
echo ""
