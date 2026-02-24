#!/bin/bash

source ../provision-scripts/_provision-scripts.lib 2>/dev/null || true

CREDS_FILE="../gen/workshop-credentials.json"
if [ -f "$CREDS_FILE" ]; then
    AZURE_RESOURCE_GROUP=$(cat "$CREDS_FILE" | jq -r '.AZURE_RESOURCE_GROUP // empty')
    AZURE_AKS_CLUSTER_NAME=$(cat "$CREDS_FILE" | jq -r '.AZURE_AKS_CLUSTER_NAME // empty')
fi

AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP:-"dynatrace-azure-workshop"}
AZURE_AKS_CLUSTER_NAME=${AZURE_AKS_CLUSTER_NAME:-"dynatrace-azure-workshop-cluster"}

echo "=========================================================="
echo "Restarting EasyTrade"
echo "=========================================================="
az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing &>/dev/null

if ! kubectl -n easytrade rollout restart deployment; then
    echo "ERROR: Failed to restart. Check if namespace exists."
    exit 1
fi
echo "  Deployments restarting..."
echo ""

# ==========================================================
# Wait for critical pods to be ready
# ==========================================================
echo "Waiting for critical pods to be ready..."
echo ""

# Wait for db pod to be ready (required for feature-flag-service)
echo -n "  Waiting for db pod: "
WAIT_COUNT=0
MAX_WAIT=60  # 5 minutes max (60 * 5 seconds)
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

# Give services a moment to fully initialize
echo "  Allowing services to stabilize (15s)..."
sleep 15

# ==========================================================
# Enable EasyTrade Problem Patterns
# ==========================================================
echo ""
echo "=========================================================="
echo "Enabling EasyTrade Problem Patterns"
echo "=========================================================="
if [ -f "./enable-easytrade-problems.sh" ]; then
    ./enable-easytrade-problems.sh
else
    echo "  SKIPPED: enable-easytrade-problems.sh not found"
fi

echo ""
echo "=========================================================="
echo "Restart Complete!"
echo "=========================================================="
echo ""
echo "Check status: kubectl -n easytrade get pods"
echo ""
