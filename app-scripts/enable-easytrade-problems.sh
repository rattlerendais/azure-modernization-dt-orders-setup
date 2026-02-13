#!/bin/bash

# ==========================================================
# Enable EasyTrade Problem Patterns
# ==========================================================
# Enables problem patterns via the feature-flag-service API
#
# Available problem patterns:
#   - factory_crisis: Factory won't produce new cards
#   - high_cpu_usage: Causes broker-service slowdown and high CPU
#   - db_not_responding: Database throws errors on new trades
#   - ergo_aggregator_slowdown: Aggregators receive slow responses
#
# Usage: ./enable-easytrade-problems.sh [--disable]
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

EASYTRADE_NAMESPACE="easytrade"
FEATURE_FLAG_SERVICE="feature-flag-service:8080"

# Check for --disable flag
ACTION="enable"
ENABLED_VALUE="true"
if [ "$1" == "--disable" ]; then
    ACTION="disable"
    ENABLED_VALUE="false"
fi

# Problem patterns to enable/disable
PROBLEM_PATTERNS=(
    "factory_crisis"
    "high_cpu_usage"
    "db_not_responding"
    "ergo_aggregator_slowdown"
)

echo "=========================================================="
echo "EasyTrade Problem Patterns - ${ACTION^}"
echo "=========================================================="
echo "  Namespace: $EASYTRADE_NAMESPACE"
echo "  Patterns:  ${PROBLEM_PATTERNS[*]}"
echo ""

# Function to set feature flag
set_feature_flag() {
    local flag_id="$1"
    local enabled="$2"

    echo -n "  Setting $flag_id to $enabled... "

    # Use kubectl exec to call the feature-flag-service from within the cluster
    local result=$(kubectl -n "$EASYTRADE_NAMESPACE" exec -i deploy/feature-flag-service -- \
        curl -s -X PUT "http://localhost:8080/v1/flags/${flag_id}" \
        -H "Content-Type: application/json" \
        -d "{\"enabled\": ${enabled}}" 2>/dev/null)

    if echo "$result" | grep -q "\"enabled\":${enabled}"; then
        echo "OK"
        return 0
    elif echo "$result" | grep -q "enabled"; then
        echo "OK (already set)"
        return 0
    else
        echo "FAILED"
        echo "       Response: $result"
        return 1
    fi
}

# Get AKS credentials if not already connected
echo "Checking cluster connection..."
if ! kubectl cluster-info &>/dev/null; then
    echo "Configuring AKS cluster credentials..."
    if ! az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing &>/dev/null; then
        echo ""
        echo "ERROR: Failed to get AKS credentials."
        exit 1
    fi
fi

# Verify feature-flag-service is running
echo "Checking feature-flag-service..."
if ! kubectl -n "$EASYTRADE_NAMESPACE" get deploy feature-flag-service &>/dev/null; then
    echo "ERROR: feature-flag-service deployment not found in namespace $EASYTRADE_NAMESPACE"
    echo "Make sure EasyTrade is deployed first."
    exit 1
fi

# Wait for feature-flag-service to be ready
echo "Waiting for feature-flag-service to be ready..."
kubectl -n "$EASYTRADE_NAMESPACE" wait --for=condition=available deploy/feature-flag-service --timeout=60s &>/dev/null

echo ""
echo "--- ${ACTION^} Problem Patterns ---"

ERRORS=0
for pattern in "${PROBLEM_PATTERNS[@]}"; do
    set_feature_flag "$pattern" "$ENABLED_VALUE" || ((ERRORS++))
done

echo ""
echo "=========================================================="
if [ $ERRORS -eq 0 ]; then
    echo "All problem patterns ${ACTION}d successfully!"
else
    echo "Completed with $ERRORS error(s)"
fi
echo "=========================================================="
echo ""
echo "To verify, check the feature flags:"
echo "  kubectl -n $EASYTRADE_NAMESPACE exec -it deploy/feature-flag-service -- curl -s http://localhost:8080/v1/flags?tag=problem_pattern"
echo ""
if [ "$ACTION" == "enable" ]; then
    echo "To disable all problem patterns:"
    echo "  ./enable-easytrade-problems.sh --disable"
fi
echo ""
