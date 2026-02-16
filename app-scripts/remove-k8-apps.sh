#!/bin/bash

# ==========================================================
# Remove Workshop K8s Applications
# ==========================================================
# This script removes all K8s applications deployed by deploy-k8-apps.sh:
#   - EasyTrade
#   - Travel Advisor
#   - Crashloop Demo
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

echo "=========================================================="
echo "Removing Workshop K8s Applications"
echo "=========================================================="
echo "  Resource Group: $AZURE_RESOURCE_GROUP"
echo "  AKS Cluster:    $AZURE_AKS_CLUSTER_NAME"
echo ""
echo "Applications to remove:"
echo "  1. EasyTrade (namespace: easytrade)"
echo "  2. Travel Advisor (namespace: travel-advisor-azure-openai-sample)"
echo "  3. Crashloop Demo (namespace: crashloop-demo)"
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

# ==========================================================
# Remove App #1 - EasyTrade
# ==========================================================
echo "=========================================================="
echo "Removing App #1 - EasyTrade"
echo "=========================================================="

EASYTRADE_NAMESPACE="easytrade"

if kubectl get namespace "$EASYTRADE_NAMESPACE" &>/dev/null; then
    echo "Deleting namespace '$EASYTRADE_NAMESPACE' and all its resources..."
    kubectl delete namespace "$EASYTRADE_NAMESPACE" --timeout=120s
    if [ $? -eq 0 ]; then
        echo "  Done."
    else
        echo "  WARNING: Namespace deletion may still be in progress"
    fi
else
    echo "  Namespace '$EASYTRADE_NAMESPACE' not found. Skipping."
fi

echo ""

# ==========================================================
# Remove App #2 - Travel Advisor
# ==========================================================
echo "=========================================================="
echo "Removing App #2 - Travel Advisor"
echo "=========================================================="

TRAVELADVISOR_NAMESPACE="travel-advisor-azure-openai-sample"

if kubectl get namespace "$TRAVELADVISOR_NAMESPACE" &>/dev/null; then
    echo "Deleting namespace '$TRAVELADVISOR_NAMESPACE' and all its resources..."
    kubectl delete namespace "$TRAVELADVISOR_NAMESPACE" --timeout=120s
    if [ $? -eq 0 ]; then
        echo "  Done."
    else
        echo "  WARNING: Namespace deletion may still be in progress"
    fi
else
    echo "  Namespace '$TRAVELADVISOR_NAMESPACE' not found. Skipping."
fi

echo ""

# ==========================================================
# Remove App #3 - Crashloop Demo
# ==========================================================
echo "=========================================================="
echo "Removing App #3 - Crashloop Demo"
echo "=========================================================="

CRASHLOOP_NAMESPACE="crashloop-demo"

if kubectl get namespace "$CRASHLOOP_NAMESPACE" &>/dev/null; then
    echo "Deleting namespace '$CRASHLOOP_NAMESPACE' and all its resources..."
    kubectl delete namespace "$CRASHLOOP_NAMESPACE" --timeout=120s
    if [ $? -eq 0 ]; then
        echo "  Done."
    else
        echo "  WARNING: Namespace deletion may still be in progress"
    fi
else
    echo "  Namespace '$CRASHLOOP_NAMESPACE' not found. Skipping."
fi

echo ""

# ==========================================================
# Summary
# ==========================================================
echo "=========================================================="
echo "Removal Complete!"
echo "=========================================================="
echo ""
echo "Verify namespaces are removed:"
echo "  kubectl get namespaces | grep -E 'easytrade|travel-advisor|crashloop'"
echo ""
echo "To redeploy applications:"
echo "  ./deploy-k8-apps.sh"
echo ""
