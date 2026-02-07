#!/bin/bash
source ../provision-scripts/_provision-scripts.lib 2>/dev/null || true

# Create namespace and deploy Hipster Shop (suppress verbose output)
kubectl create ns hipstershop 2>/dev/null || true
kubectl -n hipstershop apply -f ./manifests/hipstershop-manifest.yaml > /dev/null 2>&1

# Send event
POD_NAMES=$(kubectl -n hipstershop get pods --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
PROVISIONING_STEP="11-Provisioning app on k8-Hipstershop"
JSON_EVENT='{"id":"1","step":"'"$PROVISIONING_STEP"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step","k8pods-hipster":"'"$POD_NAMES"'","DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT" > /dev/null 2>&1
