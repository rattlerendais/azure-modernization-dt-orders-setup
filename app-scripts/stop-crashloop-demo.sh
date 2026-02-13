#!/bin/bash

# ==========================================================
# Stop Crashloop Demo
# ==========================================================
# Removes the crashloop demo deployment and namespace
# ==========================================================

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

CRASHLOOP_NAMESPACE="crashloop-demo"
MANIFEST_FILE="./manifests/crashloop-demo.yaml"

echo "=========================================================="
echo "Stopping Crashloop Demo"
echo "=========================================================="
echo "  Resource Group: $AZURE_RESOURCE_GROUP"
echo "  AKS Cluster:    $AZURE_AKS_CLUSTER_NAME"
echo "  Namespace:      $CRASHLOOP_NAMESPACE"
echo ""

# Get AKS credentials
echo "Configuring AKS cluster credentials..."
if ! az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing &>/dev/null; then
    echo ""
    echo "ERROR: Failed to get AKS credentials."
    echo "Please verify:"
    echo "  - Resource group '$AZURE_RESOURCE_GROUP' exists"
    echo "  - AKS cluster '$AZURE_AKS_CLUSTER_NAME' exists in that resource group"
    echo "  - You are logged into Azure CLI (run 'az login' if needed)"
    exit 1
fi

# Verify connectivity
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster after getting credentials."
    exit 1
fi
echo "  Connected successfully."
echo ""

# Check if namespace exists
if ! kubectl get namespace "$CRASHLOOP_NAMESPACE" &>/dev/null; then
    echo "Crashloop demo is not running (namespace '$CRASHLOOP_NAMESPACE' not found)."
    exit 0
fi

# Delete Crashloop Demo
echo "Removing Crashloop Demo..."

if [ -f "$MANIFEST_FILE" ]; then
    kubectl delete -f "$MANIFEST_FILE" 2>/dev/null
else
    # Fallback: delete namespace directly if manifest not found
    kubectl delete namespace "$CRASHLOOP_NAMESPACE" 2>/dev/null
fi

echo "  Done."

echo ""
echo "=========================================================="
echo "Crashloop Demo Stopped!"
echo "=========================================================="
echo ""
echo "To restart the crashloop demo:"
echo "  ./start-crashloop-demo.sh"
echo ""
