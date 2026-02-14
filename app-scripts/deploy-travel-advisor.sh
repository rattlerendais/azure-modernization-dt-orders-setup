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

TRAVELADVISOR_NAMESPACE="travel-advisor-azure-openai-sample"
MANIFEST_FILE="./manifests/traveladvisor-combined.yaml"

echo "=========================================================="
echo "Deploying Travel Advisor Application"
echo "=========================================================="
echo "  Resource Group: $AZURE_RESOURCE_GROUP"
echo "  AKS Cluster:    $AZURE_AKS_CLUSTER_NAME"
echo "  Namespace:      $TRAVELADVISOR_NAMESPACE"
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
# Deploy Travel Advisor
# ==========================================================
echo "Deploying Travel Advisor..."

if [ ! -f "$MANIFEST_FILE" ]; then
    echo "  ERROR: Manifest file not found: $MANIFEST_FILE"
    exit 1
fi

if kubectl apply -f "$MANIFEST_FILE"; then
    echo "  Done."
else
    echo "  WARNING: Some errors occurred during Travel Advisor deployment"
fi

# Send event for Travel Advisor
TRAVELADVISOR_POD_NAMES=$(kubectl -n "$TRAVELADVISOR_NAMESPACE" get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="12-Provisioning app on k8-TravelAdvisor"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-traveladvisor":"'"$TRAVELADVISOR_POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT" > /dev/null 2>&1

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
kubectl -n "$TRAVELADVISOR_NAMESPACE" get pods 2>/dev/null || echo "  Namespace not found or no pods yet"

echo ""
echo "=========================================================="
echo "Travel Advisor Deployment Complete!"
echo "=========================================================="
echo ""
echo "Check pod status with:"
echo "  kubectl -n $TRAVELADVISOR_NAMESPACE get pods"
echo ""
echo "To access the Travel Advisor app, get the service URL:"
echo "  kubectl -n $TRAVELADVISOR_NAMESPACE get svc"
echo ""
