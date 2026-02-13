#!/bin/bash

# ==========================================================
# Start Crashloop Demo
# ==========================================================
# Deploys a pod that continuously crashes (CrashLoopBackOff)
# Useful for demonstrating Kubernetes troubleshooting and
# Dynatrace monitoring capabilities.
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
echo "Starting Crashloop Demo"
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

# Deploy Crashloop Demo
echo "Deploying Crashloop Demo..."

if [ ! -f "$MANIFEST_FILE" ]; then
    echo "  ERROR: Manifest file not found: $MANIFEST_FILE"
    exit 1
fi

if kubectl apply -f "$MANIFEST_FILE"; then
    echo "  Done."
else
    echo "  WARNING: Some errors occurred during deployment"
fi

# Wait briefly and show status
echo ""
echo "Waiting for pod to start..."
sleep 5

echo ""
echo "=========================================================="
echo "Pod Status"
echo "=========================================================="
kubectl -n "$CRASHLOOP_NAMESPACE" get pods 2>/dev/null || echo "  Namespace not found or no pods yet"

echo ""
echo "=========================================================="
echo "Crashloop Demo Started!"
echo "=========================================================="
echo ""
echo "The pod will continuously crash and enter CrashLoopBackOff state."
echo "This is expected behavior for demonstration purposes."
echo ""
echo "Check pod status with:"
echo "  kubectl -n $CRASHLOOP_NAMESPACE get pods"
echo "  kubectl -n $CRASHLOOP_NAMESPACE describe pod crashloop-demo"
echo ""
echo "View crash logs with:"
echo "  kubectl -n $CRASHLOOP_NAMESPACE logs -l app=crashloop-demo"
echo ""
echo "To stop the crashloop demo:"
echo "  ./stop-crashloop-demo.sh"
echo ""
