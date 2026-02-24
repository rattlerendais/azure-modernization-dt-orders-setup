#!/bin/bash

source ../provision-scripts/_provision-scripts.lib 2>/dev/null || true

# Load credentials from workshop-credentials.json if available
CREDS_FILE="../gen/workshop-credentials.json"
if [ -f "$CREDS_FILE" ]; then
    AZURE_RESOURCE_GROUP=$(cat "$CREDS_FILE" | jq -r '.AZURE_RESOURCE_GROUP // empty')
    AZURE_AKS_CLUSTER_NAME=$(cat "$CREDS_FILE" | jq -r '.AZURE_AKS_CLUSTER_NAME // empty')
    EMAIL=$(cat "$CREDS_FILE" | jq -r '.EMAIL // empty')
    DT_ENVIRONMENT_ID=$(cat "$CREDS_FILE" | jq -r '.DT_ENVIRONMENT_ID // empty')
fi

# Use defaults if not set
AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP:-"dynatrace-azure-workshop"}
AZURE_AKS_CLUSTER_NAME=${AZURE_AKS_CLUSTER_NAME:-"dynatrace-azure-workshop-cluster"}

echo "=========================================================="
echo "Deploying Workshop K8s Applications"
echo "=========================================================="
echo "  Resource Group: $AZURE_RESOURCE_GROUP"
echo "  AKS Cluster:    $AZURE_AKS_CLUSTER_NAME"
echo ""
echo "Applications to deploy:"
echo "  1. EasyTrade"
echo "  2. Travel Advisor"
echo "  3. Crashloop Demo (for troubleshooting demos)"
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
# App #1 - EasyTrade
# ==========================================================
echo "=========================================================="
echo "Deploying App #1 - EasyTrade"
echo "=========================================================="

EASYTRADE_NAMESPACE="easytrade"
KUSTOMIZATION_DIR="./manifests/easytrade"

echo "Creating namespace '$EASYTRADE_NAMESPACE'..."
kubectl create ns "$EASYTRADE_NAMESPACE" 2>/dev/null || true

echo "Deploying EasyTrade using kustomization..."
if [ ! -d "$KUSTOMIZATION_DIR" ]; then
    echo "  ERROR: Kustomization directory not found: $KUSTOMIZATION_DIR"
    EASYTRADE_ERROR=true
else
    if kubectl apply -k "$KUSTOMIZATION_DIR"; then
        echo "  Done."
        EASYTRADE_ERROR=false
    else
        echo "  WARNING: Some errors occurred during EasyTrade deployment"
        EASYTRADE_ERROR=true
    fi
fi

# Send event for EasyTrade
EASYTRADE_POD_NAMES=$(kubectl -n "$EASYTRADE_NAMESPACE" get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="11-Provisioning app on k8-EasyTrade"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-easytrade":"'"$EASYTRADE_POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT" > /dev/null 2>&1

echo ""

# ==========================================================
# App #2 - Travel Advisor
# ==========================================================
echo "=========================================================="
echo "Deploying App #2 - Travel Advisor"
echo "=========================================================="

if ! kubectl apply -f manifests/traveladvisor-combined.yaml; then
    echo "  ERROR: Failed to deploy Travel Advisor"
    TRAVELADVISOR_ERROR=true
else
    echo "  Done."
    TRAVELADVISOR_ERROR=false
fi

# Send event for Travel Advisor
TRAVELADVISOR_POD_NAMES=$(kubectl -n travel-advisor-azure-openai-sample get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="12-Provisioning app on k8-TravelAdvisor"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-traveladvisor":"'"$TRAVELADVISOR_POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT" > /dev/null 2>&1

echo ""

# ==========================================================
# App #3 - Crashloop Demo
# ==========================================================
echo "=========================================================="
echo "Deploying App #3 - Crashloop Demo"
echo "=========================================================="

if ! kubectl apply -f manifests/crashloop-demo.yaml; then
    echo "  ERROR: Failed to deploy Crashloop Demo"
    CRASHLOOP_ERROR=true
else
    echo "  Done."
    CRASHLOOP_ERROR=false
fi

# ==========================================================
# Wait for critical EasyTrade pods to be ready
# ==========================================================
echo ""
echo "=========================================================="
echo "Waiting for EasyTrade Critical Pods"
echo "=========================================================="
echo "The feature-flag-service requires the database to be ready."
echo "Waiting for db and feature-flag-service pods..."
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
    echo "  WARNING: Timed out waiting for db pod. Will try to continue anyway."
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
    echo "  WARNING: Timed out waiting for feature-flag-service pod. Will try to continue anyway."
fi

# Give services a moment to fully initialize after pods are ready
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

# ==========================================================
# Seed Initial Trades for Bizevents
# ==========================================================
echo ""
echo "=========================================================="
echo "Seeding Initial Trades (for Bizevents)"
echo "=========================================================="

# Get frontend IP
FRONTEND_IP=$(kubectl -n easytrade get svc frontendreverseproxy-easytrade -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ -n "$FRONTEND_IP" ]; then
    BASE_URL="http://${FRONTEND_IP}"
    echo "  Frontend URL: $BASE_URL"

    # Wait for broker-service to be ready
    echo -n "  Waiting for broker-service: "
    WAIT_COUNT=0
    MAX_WAIT=24  # 2 minutes max
    while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/broker-service/v1/instrument" 2>/dev/null)
        if [ "$HTTP_CODE" == "200" ]; then
            echo "Ready!"
            break
        fi
        echo -n "."
        sleep 5
        ((WAIT_COUNT++))
    done

    if [ $WAIT_COUNT -ge $MAX_WAIT ]; then
        echo ""
        echo "  WARNING: broker-service not ready, skipping seed trades"
    else
        # Deposit money to test accounts (accounts 1-3)
        echo "  Depositing funds to test accounts..."
        for ACCOUNT_ID in 1 2 3; do
            curl -s -X POST "${BASE_URL}/broker-service/v1/balance/${ACCOUNT_ID}/deposit" \
                -H "Content-Type: application/json" \
                -d '{"amount": 10000, "name": "Seed Deposit", "address": "Workshop", "email": "workshop@test.com", "cardNumber": "4111111111111111", "cardType": "VISA", "cvv": "123"}' > /dev/null 2>&1
        done
        echo "    Deposited to accounts 1, 2, 3"

        # Execute seed trades
        echo "  Executing seed trades..."
        TRADE_ERRORS=0

        # Quick Buy trades (10 trades across different instruments)
        echo -n "    Quick Buy (10 trades): "
        for i in {1..10}; do
            ACCOUNT_ID=$(( (i % 3) + 1 ))
            INSTRUMENT_ID=$(( (i % 5) + 1 ))
            RESULT=$(curl -s -X POST "${BASE_URL}/broker-service/v1/trade/buy" \
                -H "Content-Type: application/json" \
                -d "{\"accountId\": ${ACCOUNT_ID}, \"instrumentId\": ${INSTRUMENT_ID}, \"amount\": $((RANDOM % 10 + 1))}" 2>/dev/null)
            if echo "$RESULT" | grep -q "transactionHappened.*true\|Instant Buy done"; then
                echo -n "."
            else
                echo -n "x"
                ((TRADE_ERRORS++))
            fi
            sleep 0.5
        done
        echo " Done"

        # Quick Sell trades (10 trades)
        echo -n "    Quick Sell (10 trades): "
        for i in {1..10}; do
            ACCOUNT_ID=$(( (i % 3) + 1 ))
            INSTRUMENT_ID=$(( (i % 5) + 1 ))
            RESULT=$(curl -s -X POST "${BASE_URL}/broker-service/v1/trade/sell" \
                -H "Content-Type: application/json" \
                -d "{\"accountId\": ${ACCOUNT_ID}, \"instrumentId\": ${INSTRUMENT_ID}, \"amount\": $((RANDOM % 5 + 1))}" 2>/dev/null)
            if echo "$RESULT" | grep -q "transactionHappened.*true\|Instant Sell done"; then
                echo -n "."
            else
                echo -n "x"
                ((TRADE_ERRORS++))
            fi
            sleep 0.5
        done
        echo " Done"

        # Long Buy trades (10 trades)
        echo -n "    Long Buy (10 trades): "
        for i in {1..10}; do
            ACCOUNT_ID=$(( (i % 3) + 1 ))
            INSTRUMENT_ID=$(( (i % 5) + 1 ))
            DURATION=$(( (RANDOM % 12) + 1 ))
            PRICE=$(( (RANDOM % 50) + 100 ))
            RESULT=$(curl -s -X POST "${BASE_URL}/broker-service/v1/trade/long/buy" \
                -H "Content-Type: application/json" \
                -d "{\"accountId\": ${ACCOUNT_ID}, \"instrumentId\": ${INSTRUMENT_ID}, \"amount\": $((RANDOM % 5 + 1)), \"duration\": ${DURATION}, \"price\": ${PRICE}}" 2>/dev/null)
            if echo "$RESULT" | grep -q "LongBuy registered"; then
                echo -n "."
            else
                echo -n "x"
                ((TRADE_ERRORS++))
            fi
            sleep 0.5
        done
        echo " Done"

        # Long Sell trades (10 trades)
        echo -n "    Long Sell (10 trades): "
        for i in {1..10}; do
            ACCOUNT_ID=$(( (i % 3) + 1 ))
            INSTRUMENT_ID=$(( (i % 5) + 1 ))
            DURATION=$(( (RANDOM % 12) + 1 ))
            PRICE=$(( (RANDOM % 50) + 100 ))
            RESULT=$(curl -s -X POST "${BASE_URL}/broker-service/v1/trade/long/sell" \
                -H "Content-Type: application/json" \
                -d "{\"accountId\": ${ACCOUNT_ID}, \"instrumentId\": ${INSTRUMENT_ID}, \"amount\": $((RANDOM % 5 + 1)), \"duration\": ${DURATION}, \"price\": ${PRICE}}" 2>/dev/null)
            if echo "$RESULT" | grep -q "LongSell registered"; then
                echo -n "."
            else
                echo -n "x"
                ((TRADE_ERRORS++))
            fi
            sleep 0.5
        done
        echo " Done"

        echo ""
        if [ $TRADE_ERRORS -eq 0 ]; then
            echo "  All 40 seed trades completed successfully!"
        else
            echo "  Seed trades completed with $TRADE_ERRORS error(s)"
        fi
        echo "  Bizevents: com.easytrade.quick-buy, quick-sell, long-buy, long-sell"
    fi
else
    echo "  SKIPPED: Could not get frontend IP"
fi

echo ""
echo "=========================================================="
echo "Pod Status Summary"
echo "=========================================================="

echo ""
echo "--- EasyTrade (namespace: easytrade) ---"
kubectl -n easytrade get pods 2>/dev/null || echo "  Namespace not found or no pods yet"

echo ""
echo "--- Travel Advisor (namespace: travel-advisor-azure-openai-sample) ---"
kubectl -n travel-advisor-azure-openai-sample get pods 2>/dev/null || echo "  Namespace not found or no pods yet"

echo ""
echo "--- Crashloop Demo (namespace: crashloop-demo) ---"
kubectl -n crashloop-demo get pods 2>/dev/null || echo "  Namespace not found or no pods yet"

echo ""
echo "=========================================================="
echo "Deployment Complete!"
echo "=========================================================="
echo ""
echo "NOTE: EasyTrade has many services and may take several minutes"
echo "      for all pods to reach 'Running' status."
echo ""
echo "Check pod status with:"
echo "  kubectl -n easytrade get pods"
echo "  kubectl -n travel-advisor-azure-openai-sample get pods"
echo "  kubectl -n crashloop-demo get pods"
echo ""
echo "To access EasyTrade frontend:"
echo "  kubectl -n easytrade get svc frontendreverseproxy"
echo ""
echo "To stop/start crashloop demo:"
echo "  ./stop-crashloop-demo.sh"
echo "  ./start-crashloop-demo.sh"
echo ""
