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
echo ""

# Get AKS credentials
echo "Running: az aks get-credentials --resource-group $AZURE_RESOURCE_GROUP --name $AZURE_AKS_CLUSTER_NAME --overwrite-existing"
if ! az aks get-credentials --resource-group "$AZURE_RESOURCE_GROUP" --name "$AZURE_AKS_CLUSTER_NAME" --overwrite-existing 2>/dev/null; then
    echo ""
    echo "ERROR: Failed to get AKS credentials."
    echo "Please verify:"
    echo "  - Resource group '$AZURE_RESOURCE_GROUP' exists"
    echo "  - AKS cluster '$AZURE_AKS_CLUSTER_NAME' exists in that resource group"
    echo "  - You are logged into Azure CLI (run 'az login' if needed)"
    echo ""
    exit 1
fi

# Verify connectivity
echo ""
echo "Verifying cluster connectivity..."
if ! kubectl cluster-info &>/dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster after getting credentials."
    exit 1
fi
echo "Connected to AKS cluster successfully."
echo ""

echo "=========================================================="
echo "Starting app on k8"
echo "=========================================================="

echo "=========================================================="
echo "Start App #1 - Hipster shop"
echo "=========================================================="
./start-k8-hipstershop.sh


echo "=========================================================="
echo "Start App#2 - DT Orders"
echo "=========================================================="

echo "----------------------------------------------------------"
echo "kubectl create namespace staging"
echo "----------------------------------------------------------"
kubectl create ns staging

echo "----------------------------------------------------------"
echo "kubectl create -f manifests/dynatrace-oneagent-metadata-viewer.yaml"
echo "----------------------------------------------------------"
kubectl create -f manifests/dynatrace-oneagent-metadata-viewer.yaml

echo "----------------------------------------------------------"
echo "kubectl -n staging apply -f catalog-service.yml"
echo "----------------------------------------------------------"
kubectl -n staging apply -f manifests/catalog-service.yml

echo "----------------------------------------------------------"
echo "kubectl -n staging apply -f manifests/customer-service.yml"
echo "----------------------------------------------------------"
kubectl -n staging apply -f manifests/customer-service.yml

echo "----------------------------------------------------------"
echo "kubectl -n staging apply -f manifests/order-service.yml"
echo "----------------------------------------------------------"
kubectl -n staging apply -f manifests/order-service.yml

echo "----------------------------------------------------------"
echo "kubectl -n staging apply -f manifests/frontend.yml"
echo "----------------------------------------------------------"
kubectl -n staging apply -f manifests/frontend.yml

echo "----------------------------------------------------------"
echo "kubectl -n staging apply -f manifests/browser-traffic.yml"
echo "----------------------------------------------------------"
kubectl -n staging apply -f manifests/browser-traffic.yml

echo "----------------------------------------------------------"
echo "kubectl -n staging apply -f manifests/load-traffic.yml"
echo "----------------------------------------------------------"
kubectl -n staging apply -f manifests/load-traffic.yml

echo "----------------------------------------------------------"
echo "kubectl -n staging get pods"
echo "----------------------------------------------------------"
sleep 5
kubectl -n staging get pods
POD_NAMES=$(kubectl -n staging get pods --no-headers -o custom-columns=":metadata.name")
PROVISIONING_STEP="11-Provisioning app on k8-DTOrders"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-staging":"'"$POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
DT_SEND_EVENT=$(curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT")

echo "=========================================================="
echo "Start App #3 - Travel Advisor (Azure OpenAI)"
echo "=========================================================="

echo "----------------------------------------------------------"
echo "kubectl apply -f manifests/traveladvisor-combined.yaml"
echo "----------------------------------------------------------"
kubectl apply -f manifests/traveladvisor-combined.yaml

echo "----------------------------------------------------------"
echo "kubectl -n travel-advisor-azure-openai-sample get pods"
echo "----------------------------------------------------------"
sleep 5
kubectl -n travel-advisor-azure-openai-sample get pods

echo "----------------------------------------------------------"
echo "kubectl -n travel-advisor-azure-openai-sample get svc"
echo "----------------------------------------------------------"
kubectl -n travel-advisor-azure-openai-sample get svc

TRAVELADVISOR_POD_NAMES=$(kubectl -n travel-advisor-azure-openai-sample get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="12-Provisioning app on k8-TravelAdvisor"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-traveladvisor":"'"$TRAVELADVISOR_POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
DT_SEND_EVENT=$(curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT")

echo "=========================================================="
echo "All Kubernetes apps deployed!"
echo "=========================================================="