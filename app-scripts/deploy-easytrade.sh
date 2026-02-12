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

EASYTRADE_NAMESPACE="easytrade"
GITHUB_RAW_BASE="https://raw.githubusercontent.com/Dynatrace/easytrade/main/kubernetes-manifests/release"

echo "=========================================================="
echo "Deploying EasyTrade Application"
echo "=========================================================="
echo "  Resource Group: $AZURE_RESOURCE_GROUP"
echo "  AKS Cluster:    $AZURE_AKS_CLUSTER_NAME"
echo "  Namespace:      $EASYTRADE_NAMESPACE"
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

# Create namespace
echo "Creating namespace '$EASYTRADE_NAMESPACE'..."
kubectl create ns "$EASYTRADE_NAMESPACE" 2>/dev/null || true

# ==========================================================
# Deploy EasyTrade manifests from GitHub
# ==========================================================
echo ""
echo "Deploying EasyTrade manifests from GitHub..."
echo ""

EASYTRADE_ERROR=false

# Core infrastructure (deploy first)
echo "  Deploying core infrastructure..."
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/connection-strings.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/db.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/rabbitmq.yaml" || EASYTRADE_ERROR=true

# Feature flag service
echo "  Deploying feature flag service..."
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/feature-flag-service.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/feature-flag-service-setup.yaml" || EASYTRADE_ERROR=true

# Application services
echo "  Deploying application services..."
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/accountservice.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/aggregator-service.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/broker-service.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/calculationservice.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/contentcreator.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/credit-card-order-service.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/engine.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/loginservice.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/manager.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/offerservice.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/pricing-service.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/third-party-service.yaml" || EASYTRADE_ERROR=true

# Frontend
echo "  Deploying frontend..."
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/frontend.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/frontendreverseproxy.yaml" || EASYTRADE_ERROR=true

# Problem operator and load generator
echo "  Deploying problem operator and load generator..."
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/problem-operator.yaml" || EASYTRADE_ERROR=true
kubectl -n "$EASYTRADE_NAMESPACE" apply -f "$GITHUB_RAW_BASE/loadgen.yaml" || EASYTRADE_ERROR=true

if [ "$EASYTRADE_ERROR" = true ]; then
    echo ""
    echo "  WARNING: Some errors occurred during EasyTrade deployment"
else
    echo ""
    echo "  Done."
fi

# Send event for EasyTrade
EASYTRADE_POD_NAMES=$(kubectl -n "$EASYTRADE_NAMESPACE" get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="13-Provisioning app on k8-EasyTrade"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-easytrade":"'"$EASYTRADE_POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
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
kubectl -n "$EASYTRADE_NAMESPACE" get pods 2>/dev/null || echo "  Namespace not found or no pods yet"

echo ""
echo "=========================================================="
echo "EasyTrade Deployment Complete!"
echo "=========================================================="
echo ""
echo "NOTE: EasyTrade has many services. It may take several minutes"
echo "      for all pods to reach 'Running' status."
echo ""
echo "Check pod status with:"
echo "  kubectl -n $EASYTRADE_NAMESPACE get pods"
echo ""
echo "To access the EasyTrade frontend, get the service URL:"
echo "  kubectl -n $EASYTRADE_NAMESPACE get svc frontendreverseproxy"
echo ""
