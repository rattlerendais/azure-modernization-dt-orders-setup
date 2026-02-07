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
echo "Configuring AKS cluster credentials..."
echo "=========================================================="
echo "Resource Group: $AZURE_RESOURCE_GROUP"
echo "AKS Cluster:    $AZURE_AKS_CLUSTER_NAME"

# Get AKS credentials
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
echo "Connected to AKS cluster successfully."
echo ""

# ==========================================================
# App #1 - Hipster Shop
# ==========================================================
echo "=========================================================="
echo "Deploying App #1 - Hipster Shop"
echo "=========================================================="
./start-k8-hipstershop.sh 2>/dev/null
echo "Hipster Shop deployment initiated."
echo ""

# ==========================================================
# App #2 - DT Orders
# ==========================================================
echo "=========================================================="
echo "Deploying App #2 - DT Orders"
echo "=========================================================="
kubectl create ns staging 2>/dev/null || true
kubectl create -f manifests/dynatrace-oneagent-metadata-viewer.yaml 2>/dev/null || true
kubectl -n staging apply -f manifests/catalog-service.yml -o name 2>/dev/null
kubectl -n staging apply -f manifests/customer-service.yml -o name 2>/dev/null
kubectl -n staging apply -f manifests/order-service.yml -o name 2>/dev/null
kubectl -n staging apply -f manifests/frontend.yml -o name 2>/dev/null
kubectl -n staging apply -f manifests/browser-traffic.yml -o name 2>/dev/null
kubectl -n staging apply -f manifests/load-traffic.yml -o name 2>/dev/null
echo "DT Orders deployment initiated."

# Send event for DT Orders
POD_NAMES=$(kubectl -n staging get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="11-Provisioning app on k8-DTOrders"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-staging":"'"$POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT" > /dev/null 2>&1
echo ""

# ==========================================================
# App #3 - Travel Advisor
# ==========================================================
echo "=========================================================="
echo "Deploying App #3 - Travel Advisor (Azure OpenAI)"
echo "=========================================================="
kubectl apply -f manifests/traveladvisor-combined.yaml -o name 2>/dev/null
echo "Travel Advisor deployment initiated."

# Send event for Travel Advisor
TRAVELADVISOR_POD_NAMES=$(kubectl -n travel-advisor-azure-openai-sample get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="12-Provisioning app on k8-TravelAdvisor"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-traveladvisor":"'"$TRAVELADVISOR_POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT" > /dev/null 2>&1
echo ""

# ==========================================================
# Wait for pods to start and show status
# ==========================================================
echo "=========================================================="
echo "Waiting for pods to initialize..."
echo "=========================================================="
sleep 10

echo ""
echo "=========================================================="
echo "Pod Status Summary"
echo "=========================================================="

echo ""
echo "--- Hipster Shop (namespace: hipster-shop) ---"
kubectl -n hipster-shop get pods 2>/dev/null || echo "Namespace not found or no pods yet"

echo ""
echo "--- DT Orders (namespace: staging) ---"
kubectl -n staging get pods 2>/dev/null || echo "Namespace not found or no pods yet"

echo ""
echo "--- Travel Advisor (namespace: travel-advisor-azure-openai-sample) ---"
kubectl -n travel-advisor-azure-openai-sample get pods 2>/dev/null || echo "Namespace not found or no pods yet"

echo ""
echo "=========================================================="
echo "Deployment Complete!"
echo "=========================================================="
echo ""
echo "NOTE: If any pods are not in 'Running' status, wait a few"
echo "      minutes and re-run this script or check pod status with:"
echo ""
echo "      kubectl -n hipster-shop get pods"
echo "      kubectl -n staging get pods"
echo "      kubectl -n travel-advisor-azure-openai-sample get pods"
echo ""
