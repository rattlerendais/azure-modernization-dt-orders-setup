#!/bin/bash

YLW='\033[1;33m'
RED='\033[0;31m'
GRN='\033[0;32m'
NC='\033[0m'
PROVISIONING_STEP="01-Input-credentials"

CREDS_TEMPLATE_FILE="./workshop-credentials.template"
CREDS_FILE="../gen/workshop-credentials.json"

# Dynatrace Event Tracking
DT_EVENT_ENDPOINT="https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event"

# Send event to Dynatrace (called after we have EMAIL and DT_ENVIRONMENT_ID)
send_dt_event() {
    local step=$1
    local extra_data=${2:-""}

    # Only send if both EMAIL and DT_ENVIRONMENT_ID are set
    if [ -n "$EMAIL" ] && [ -n "$DT_ENVIRONMENT_ID" ]; then
        local JSON_EVENT='{"id":"1","step":"'"$step"'","event.provider":"azure-workshop-provisioning","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"provisioning-step"'"$extra_data"',"DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
        curl -s -X POST "$DT_EVENT_ENDPOINT" \
            -H "Content-Type: application/json" \
            -d "$JSON_EVENT" > /dev/null 2>&1
    fi
}

# Load existing credentials if available
if [ -f "$CREDS_FILE" ]; then
    DT_BASEURL=$(cat $CREDS_FILE | jq -r '.DT_BASEURL // empty')
    DT_PLATFORM_TOKEN=$(cat $CREDS_FILE | jq -r '.DT_PLATFORM_TOKEN // empty')
    DT_ENVIRONMENT_ID=$(cat $CREDS_FILE | jq -r '.DT_ENVIRONMENT_ID // empty')
    AZURE_RESOURCE_GROUP=$(cat $CREDS_FILE | jq -r '.AZURE_RESOURCE_GROUP // empty')
    AZURE_SUBSCRIPTION=$(cat $CREDS_FILE | jq -r '.AZURE_SUBSCRIPTION // empty')
    AZURE_LOCATION=$(cat $CREDS_FILE | jq -r '.AZURE_LOCATION // empty')
    RESOURCE_PREFIX=$(cat $CREDS_FILE | jq -r '.RESOURCE_PREFIX // empty')
fi

# Get default Azure subscription if not set
if [ -z "$AZURE_SUBSCRIPTION" ]; then
    AZURE_SUBSCRIPTION_ID=$(az account list --all --query "[?isDefault].id" --output tsv)
    AZURE_SUBSCRIPTION=$AZURE_SUBSCRIPTION_ID
fi

# Default location
AZURE_LOCATION=${AZURE_LOCATION:-"eastus"}

clear
echo "==================================================================="
echo -e "${YLW}Dynatrace Azure Workshop - Credentials Setup${NC}"
echo "==================================================================="
echo -e "${YLW}Enter your credentials:${NC}"
echo "Press <enter> to keep the current value"
echo "==================================================================="
echo ""

# Collect Dynatrace Base URL
echo "Dynatrace Environment URL (ex. https://abc12345.apps.dynatrace.com)"
read -p "                         (current: $DT_BASEURL) : " DT_BASEURL_NEW

# Collect Platform Token
echo ""
echo "Dynatrace Platform Token (starts with dt0s16.)"
read -p "                         (current: ${DT_PLATFORM_TOKEN:+****${DT_PLATFORM_TOKEN: -8}}) : " DT_PLATFORM_TOKEN_NEW

echo ""
echo "==================================================================="

# Set values (new input or keep current)
RESOURCE_PREFIX=${RESOURCE_PREFIX_NEW:-$RESOURCE_PREFIX}
DT_BASEURL=${DT_BASEURL_NEW:-$DT_BASEURL}
DT_PLATFORM_TOKEN=${DT_PLATFORM_TOKEN_NEW:-$DT_PLATFORM_TOKEN}
# Azure Subscription is auto-detected from az account list

# Set resource names based on prefix
if [ -n "$RESOURCE_PREFIX" ]; then
    AZURE_RESOURCE_GROUP="dynatrace-azure-workshop-$RESOURCE_PREFIX"
    AZURE_AKS_CLUSTER_NAME="dynatrace-azure-workshop-cluster-$RESOURCE_PREFIX"
    AZURE_AIFOUNDRY_NAME="dynatrace-azure-workshop-aifoundry-$RESOURCE_PREFIX"
else
    AZURE_RESOURCE_GROUP="dynatrace-azure-workshop"
    AZURE_AKS_CLUSTER_NAME="dynatrace-azure-workshop-cluster"
    AZURE_AIFOUNDRY_NAME="dynatrace-azure-workshop-aifoundry"
fi

# Initialize AI Foundry endpoint and key as empty
AZURE_AIFOUNDRY_ENDPOINT=""
AZURE_AIFOUNDRY_MODEL_KEY=""

# Get user email from Azure
EMAIL=$(az account show --query user.name --output tsv 2>/dev/null)
EMAIL=$(echo $EMAIL | cut -d'#' -f 2)

# Extract DT_ENVIRONMENT_ID from the URL
# Supports patterns:
#   https://{env-id}.apps.dynatrace.com (Gen3/Platform)
#   https://{env-id}.live.dynatrace.com (Gen2/Classic)
#   https://{domain}/e/{env-id} (Managed)
#   https://{env-id}.sprint.dynatracelabs.com (Sprint)

if [[ $(echo $DT_BASEURL | grep "/e/" | wc -l) == *"1"* ]]; then
    # Managed: https://{domain}/e/{env-id}
    DT_ENVIRONMENT_ID=$(echo $DT_BASEURL | awk -F"/e/" '{ print $2 }')
elif [[ $(echo $DT_BASEURL | grep ".live." | wc -l) == *"1"* ]]; then
    # Gen2: https://{env-id}.live.dynatrace.com
    DT_ENVIRONMENT_ID=$(echo $DT_BASEURL | awk -F"." '{ print $1 }' | awk -F"https://" '{ print $2 }')
elif [[ $(echo $DT_BASEURL | grep ".sprint." | wc -l) == *"1"* ]]; then
    # Sprint: https://{env-id}.sprint.dynatracelabs.com
    DT_ENVIRONMENT_ID=$(echo $DT_BASEURL | awk -F"." '{ print $1 }' | awk -F"https://" '{ print $2 }')
elif [[ $(echo $DT_BASEURL | grep ".apps." | wc -l) == *"1"* ]]; then
    # Gen3/Platform: https://{env-id}.apps.dynatrace.com
    DT_ENVIRONMENT_ID=$(echo $DT_BASEURL | awk -F"." '{ print $1 }' | awk -F"https://" '{ print $2 }')
else
    echo ""
    echo -e "${RED}ERROR: Could not extract Environment ID from URL: $DT_BASEURL${NC}"
    echo "Expected format: https://{env-id}.apps.dynatrace.com"
    exit 1
fi

# Remove trailing slash if present
if [ "${DT_BASEURL: -1}" == "/" ]; then
    DT_BASEURL="$(echo ${DT_BASEURL%?})"
fi

# Set both Gen2 (live) and Gen3 (platform) URLs
DT_BASEURL_LIVE="https://$DT_ENVIRONMENT_ID.live.dynatrace.com"
DT_BASEURL_PLATFORM="https://$DT_ENVIRONMENT_ID.apps.dynatrace.com"

# Validate Platform Token format
if [[ ! "$DT_PLATFORM_TOKEN" =~ ^dt0s ]]; then
    echo ""
    echo -e "${RED}WARNING: Platform Token doesn't start with 'dt0s'.${NC}"
    echo "Make sure you created a Platform Token (not a classic API token)."
    echo ""
    read -p "Do you want to continue anyway? (y/n) : " CONTINUE_REPLY
    if [ "$CONTINUE_REPLY" != "y" ]; then
        echo "Exiting. Please create a Platform Token and try again."
        exit 1
    fi
fi

# Verify token works by making a simple API call
echo ""
echo "Verifying Platform Token..."
# Use Settings 2.0 schemas endpoint to verify token (requires settings:schemas:read scope)
VERIFY_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    "${DT_BASEURL_PLATFORM}/platform/classic/environment-api/v2/settings/schemas" \
    -H "Authorization: Bearer $DT_PLATFORM_TOKEN" 2>/dev/null)

if [ "$VERIFY_RESULT" == "200" ]; then
    echo -e "${GRN}Platform Token verified successfully!${NC}"
    send_dt_event "01-Input-credentials-TOKEN-VERIFIED" ',"status":"Platform token verified"'
else
    echo -e "${RED}WARNING: Could not verify Platform Token (HTTP $VERIFY_RESULT)${NC}"
    echo "The token may be invalid or missing required scopes."
    echo ""
    read -p "Do you want to continue anyway? (y/n) : " CONTINUE_REPLY
    if [ "$CONTINUE_REPLY" != "y" ]; then
        echo "Exiting. Please verify your Platform Token and try again."
        exit 1
    fi
    send_dt_event "01-Input-credentials-TOKEN-FAILED" ',"status":"Platform token verification failed","http_code":"'"$VERIFY_RESULT"'"'
fi

# Display summary for confirmation
echo ""
echo "==================================================================="
echo -e "${YLW}Please confirm all values are correct:${NC}"
echo "==================================================================="
echo ""
echo "Dynatrace Settings:"
echo "  Environment ID     : $DT_ENVIRONMENT_ID"
echo "  Platform URL (Gen3): $DT_BASEURL_PLATFORM"
echo "  Live URL (Gen2)    : $DT_BASEURL_LIVE"
echo "  Platform Token     : ****${DT_PLATFORM_TOKEN: -8}"
echo ""
echo "Azure Settings:"
echo "  Subscription ID    : $AZURE_SUBSCRIPTION"
echo "  Resource Group     : $AZURE_RESOURCE_GROUP"
echo "  AKS Cluster Name   : $AZURE_AKS_CLUSTER_NAME"
echo "  Location           : $AZURE_LOCATION"
echo ""
echo "==================================================================="
read -p "Is this all correct? (y/n) : " REPLY
if [ "$REPLY" != "y" ]; then
    echo "Exiting. Run this script again to re-enter credentials."
    exit 0
fi

echo ""
echo "==================================================================="

# Backup existing credentials file
cp $CREDS_FILE $CREDS_FILE.bak 2>/dev/null
rm $CREDS_FILE 2>/dev/null

# Create credentials file from template
cat $CREDS_TEMPLATE_FILE | \
    sed 's~RESOURCE_PREFIX_PLACEHOLDER~'"$RESOURCE_PREFIX"'~' | \
    sed 's~DT_ENVIRONMENT_ID_PLACEHOLDER~'"$DT_ENVIRONMENT_ID"'~' | \
    sed 's~DT_BASEURL_PLACEHOLDER~'"$DT_BASEURL_LIVE"'~' | \
    sed 's~DT_BASEURL_LIVE_PLACEHOLDER~'"$DT_BASEURL_LIVE"'~' | \
    sed 's~DT_BASEURL_PLATFORM_PLACEHOLDER~'"$DT_BASEURL_PLATFORM"'~' | \
    sed 's~DT_PLATFORM_TOKEN_PLACEHOLDER~'"$DT_PLATFORM_TOKEN"'~' | \
    sed 's~DT_API_TOKEN_PLACEHOLDER~'"$DT_PLATFORM_TOKEN"'~' | \
    sed 's~DT_PAAS_TOKEN_PLACEHOLDER~'"$DT_PLATFORM_TOKEN"'~' | \
    sed 's~DT_ACCESS_API_TOKEN_PLACEHOLDER~'"$DT_PLATFORM_TOKEN"'~' | \
    sed 's~AZURE_SUBSCRIPTION_PLACEHOLDER~'"$AZURE_SUBSCRIPTION"'~' | \
    sed 's~AZURE_RESOURCE_GROUP_PLACEHOLDER~'"$AZURE_RESOURCE_GROUP"'~' | \
    sed 's~AZURE_LOCATION_PLACEHOLDER~'"$AZURE_LOCATION"'~' | \
    sed 's~AZURE_AKS_CLUSTER_NAME_PLACEHOLDER~'"$AZURE_AKS_CLUSTER_NAME"'~' | \
    sed 's~AZURE_AIFOUNDRY_NAME_PLACEHOLDER~'"$AZURE_AIFOUNDRY_NAME"'~' | \
    sed 's~DT_DASHBOARD_OWNER_EMAIL_PLACEHOLDER~'"$EMAIL"'~' | \
    sed 's~EMAIL_PLACEHOLDER~'"$EMAIL"'~' | \
    sed 's~AZURE_AIFOUNDRY_ENDPOINT_PLACEHOLDER~'"$AZURE_AIFOUNDRY_ENDPOINT"'~' | \
    sed 's~AZURE_AIFOUNDRY_MODEL_KEY_PLACEHOLDER~'"$AZURE_AIFOUNDRY_MODEL_KEY"'~' > $CREDS_FILE

echo -e "${GRN}Credentials saved to: $CREDS_FILE${NC}"

# Send credentials saved event
send_dt_event "01-Input-credentials-SAVED" ',"status":"Credentials saved successfully"'

# Send final completion event
JSON_EVENT=$(cat <<EOF
{
  "id": "1",
  "step": "$PROVISIONING_STEP",
  "event.provider": "azure-workshop-provisioning",
  "event.category": "azure-workshop",
  "user": "$EMAIL",
  "event.type": "provisioning-step",
  "DT_ENVIRONMENT_ID": "$DT_ENVIRONMENT_ID"
}
EOF
)

curl -s -X POST "$DT_EVENT_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "$JSON_EVENT" > /dev/null 2>&1
