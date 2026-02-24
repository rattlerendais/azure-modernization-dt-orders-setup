#!/bin/bash

# ==========================================================
# Enable EasyTrade Problem Patterns
# ==========================================================
# Enables problem patterns via the feature-flag-service API
#
# Available problem patterns:
#   - factory_crisis: Factory won't produce new cards
#   - high_cpu_usage: Causes broker-service slowdown and high CPU
#   - credit_card_meltdown: OrderController service error
#
# Note: db_not_responding is NOT enabled by default as it blocks
#       all trades, preventing buy/sell bizevents from being generated.
#       Enable manually if needed for specific demos.
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
# Note: db_not_responding excluded - it blocks all trades
PROBLEM_PATTERNS=(
    "factory_crisis"
    "high_cpu_usage"
    "credit_card_meltdown"
)

echo "=========================================================="
echo "EasyTrade Problem Patterns - ${ACTION^}"
echo "=========================================================="
echo "  Namespace: $EASYTRADE_NAMESPACE"
echo "  Patterns:  ${PROBLEM_PATTERNS[*]}"
echo ""

# Function to set feature flag (with retries)
set_feature_flag() {
    local base_url="$1"
    local flag_id="$2"
    local enabled="$3"
    local max_retries=3
    local retry_count=0

    echo -n "  Setting $flag_id to $enabled... "

    while [ $retry_count -lt $max_retries ]; do
        local result=$(curl -s -X PUT "${base_url}/feature-flag-service/v1/flags/${flag_id}" \
            -H "Content-Type: application/json" \
            -d "{\"enabled\": ${enabled}}" 2>/dev/null)

        if echo "$result" | grep -q "\"enabled\":${enabled}"; then
            echo "OK"
            return 0
        elif echo "$result" | grep -q "\"enabled\""; then
            echo "OK (already set)"
            return 0
        elif echo "$result" | grep -q "502 Bad Gateway\|503 Service\|504 Gateway"; then
            ((retry_count++))
            if [ $retry_count -lt $max_retries ]; then
                echo -n "retry... "
                sleep 5
            fi
        else
            echo "FAILED"
            if [ -n "$result" ]; then
                echo "       Response: $result"
            fi
            return 1
        fi
    done

    echo "FAILED (after $max_retries retries)"
    return 1
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
FRONTEND_IP=$(kubectl -n "$EASYTRADE_NAMESPACE" get svc frontendreverseproxy-easytrade -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ -z "$FRONTEND_IP" ]; then
    echo "ERROR: Could not get frontendreverseproxy-easytrade external IP"
    echo "Make sure EasyTrade is deployed and the LoadBalancer has an IP assigned."
    echo ""
    echo "Check with: kubectl -n $EASYTRADE_NAMESPACE get svc frontendreverseproxy-easytrade"
    exit 1
fi

BASE_URL="http://${FRONTEND_IP}"
echo "  Frontend URL: $BASE_URL"

# Verify feature-flag-service is accessible (with retries)
echo "Checking feature-flag-service connectivity..."
MAX_RETRIES=12  # 12 retries * 10 seconds = 2 minutes max
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    RESPONSE=$(curl -s -w "\n%{http_code}" "${BASE_URL}/feature-flag-service/v1/flags" 2>/dev/null)
    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

    if [ "$HTTP_CODE" == "200" ]; then
        echo "  Connected successfully."
        break
    elif [ "$HTTP_CODE" == "502" ] || [ "$HTTP_CODE" == "503" ] || [ "$HTTP_CODE" == "504" ]; then
        ((RETRY_COUNT++))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "  Service not ready (HTTP $HTTP_CODE), retrying in 10 seconds... ($RETRY_COUNT/$MAX_RETRIES)"
            sleep 10
        fi
    else
        ((RETRY_COUNT++))
        if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
            echo "  Connection failed (HTTP $HTTP_CODE), retrying in 10 seconds... ($RETRY_COUNT/$MAX_RETRIES)"
            sleep 10
        fi
    fi
done

if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "ERROR: Unable to connect to feature-flag-service after $MAX_RETRIES attempts"
    echo "The database or feature-flag-service may still be starting up."
    echo ""
    echo "Check pod status with:"
    echo "  kubectl -n $EASYTRADE_NAMESPACE get pods"
    echo ""
    echo "You can retry manually with:"
    echo "  ./enable-easytrade-problems.sh"
    exit 1
fi

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
