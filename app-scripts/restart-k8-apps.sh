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
# Restart EasyTrade
# ==========================================================
echo "Restarting EasyTrade (namespace: easytrade)..."
if kubectl -n easytrade rollout restart deployment 2>/dev/null; then
    echo "  Done."
    EASYTRADE_RESTARTED=true
else
    echo "  WARNING: No deployments found or namespace doesn't exist"
    EASYTRADE_RESTARTED=false
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

# ==========================================================
# Wait for EasyTrade critical pods and enable problem patterns
# ==========================================================
if [ "$EASYTRADE_RESTARTED" = true ]; then
    echo ""
    echo "=========================================================="
    echo "Waiting for EasyTrade Critical Pods"
    echo "=========================================================="

    # Wait for db pod to be ready
    echo -n "  Waiting for db pod: "
    WAIT_COUNT=0
    MAX_WAIT=60
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        DB_READY=$(kubectl -n easytrade get pods -l app=db -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
        if [ "$DB_READY" == "true" ]; then
            echo "Ready!"
            break
        fi
        echo -n "."
        sleep 5
        ((WAIT_COUNT++))
    done
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo ""
        echo "  WARNING: Timed out waiting for db pod."
    fi

    # Wait for feature-flag-service pod to be ready
    echo -n "  Waiting for feature-flag-service pod: "
    WAIT_COUNT=0
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        FFS_READY=$(kubectl -n easytrade get pods -l app=feature-flag-service -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)
        if [ "$FFS_READY" == "true" ]; then
            echo "Ready!"
            break
        fi
        echo -n "."
        sleep 5
        ((WAIT_COUNT++))
    done
    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo ""
        echo "  WARNING: Timed out waiting for feature-flag-service pod."
    fi

    # Give services time to stabilize
    echo "  Allowing services to stabilize (15s)..."
    sleep 15

    # Enable problem patterns
    echo ""
    echo "=========================================================="
    echo "Enabling EasyTrade Problem Patterns"
    echo "=========================================================="
    if [ -f "./enable-easytrade-problems.sh" ]; then
        ./enable-easytrade-problems.sh
    else
        echo "  SKIPPED: enable-easytrade-problems.sh not found"
    fi
fi

echo ""
echo "=========================================================="
echo "Restart Complete!"
echo "=========================================================="
echo ""
echo "Check pod status with:"
echo "  kubectl -n easytrade get pods"
echo "  kubectl -n travel-advisor-azure-openai-sample get pods"
echo ""
