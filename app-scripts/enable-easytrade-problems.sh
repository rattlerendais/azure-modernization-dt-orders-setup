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
#   - credit_card_meltdown: OrderController service error
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
    "credit_card_meltdown"
)

echo "=========================================================="
echo "EasyTrade Problem Patterns - ${ACTION^}"
echo "=========================================================="
echo "  Namespace: $EASYTRADE_NAMESPACE"
echo "  Patterns:  ${PROBLEM_PATTERNS[*]}"
echo ""

# Function to set feature flag
set_feature_flag() {
    local base_url="$1"
    local flag_id="$2"
    local enabled="$3"

    echo -n "  Setting $flag_id to $enabled... "

    local result=$(curl -s -X PUT "${base_url}/feature-flag-service/v1/flags/${flag_id}" \
        -H "Content-Type: application/json" \
        -d "{\"enabled\": ${enabled}}" 2>/dev/null)

    if echo "$result" | grep -q "\"enabled\":${enabled}"; then
        echo "OK"
        return 0
    elif echo "$result" | grep -q "\"enabled\""; then
        echo "OK (already set)"
        return 0
    else
        echo "FAILED"
        if [ -n "$result" ]; then
            echo "       Response: $result"
        fi
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

# Get the external IP of frontendreverseproxy
echo "Getting EasyTrade frontend IP..."
FRONTEND_IP=$(kubectl -n "$EASYTRADE_NAMESPACE" get svc frontendreverseproxy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ -z "$FRONTEND_IP" ]; then
    echo "ERROR: Could not get frontendreverseproxy external IP"
    echo "Make sure EasyTrade is deployed and the LoadBalancer has an IP assigned."
    echo ""
    echo "Check with: kubectl -n $EASYTRADE_NAMESPACE get svc frontendreverseproxy"
    exit 1
fi

BASE_URL="http://${FRONTEND_IP}"
echo "  Frontend URL: $BASE_URL"

# Verify feature-flag-service is accessible
echo "Checking feature-flag-service connectivity..."
if ! curl -s "${BASE_URL}/feature-flag-service/v1/flags" &>/dev/null; then
    echo "ERROR: Unable to connect to feature-flag-service"
    echo "The service may still be starting up. Try again in a few moments."
    exit 1
fi
echo "  Connected successfully."

echo ""
echo "--- ${ACTION^} Problem Patterns ---"

ERRORS=0
for pattern in "${PROBLEM_PATTERNS[@]}"; do
    set_feature_flag "$BASE_URL" "$pattern" "$ENABLED_VALUE" || ((ERRORS++))
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
if [ "$ACTION" == "enable" ]; then
    echo "To disable all problem patterns:"
    echo "  ./enable-easytrade-problems.sh --disable"
fi
echo ""
