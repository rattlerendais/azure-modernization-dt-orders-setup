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
# Wait for pods to start and show status
# ==========================================================
echo ""
echo "Waiting for pods to initialize..."
sleep 10

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
