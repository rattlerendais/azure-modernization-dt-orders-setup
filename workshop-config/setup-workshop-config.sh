#!/bin/bash

# =============================================================================
# Workshop Configuration Script - Monaco + Direct API
# =============================================================================
# This script uses:
#   - Monaco v2 for Classic API configs (custom-services, conditional-naming, dashboard, synthetics)
#   - Direct Settings 2.0 API calls for settings configurations
#
# Usage: ./setup-workshop-config.sh [setup-type] [options]
#   setup-type: synthetics, dashboard, or blank for full workshop config
#   options: --verbose for detailed output
# =============================================================================

# Change to script directory to ensure relative paths work
cd "$(dirname "$0")"

source ./_workshop-config.lib

# Parse arguments
SETUP_TYPE=""
DASHBOARD_OWNER_EMAIL=""
VERBOSE=false

for arg in "$@"; do
    case $arg in
        --verbose|-v)
            VERBOSE=true
            ;;
        *)
            if [ -z "$SETUP_TYPE" ]; then
                SETUP_TYPE=$arg
            elif [ -z "$DASHBOARD_OWNER_EMAIL" ]; then
                DASHBOARD_OWNER_EMAIL=$arg
            fi
            ;;
    esac
done

# Tool versions
MONACO_V2_VERSION="2.28.1"

# Configuration paths
MONACO_V2_MANIFEST=./monaco-v2/manifest.yaml

# Log files
MONACO_LOG_FILE="/tmp/monaco-deploy-$$.log"

# Event endpoint
EVENT_ENDPOINT="https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event"

# =============================================================================
# Helper Functions
# =============================================================================

send_event() {
    local step="$1"
    local status="${2:-running}"
    local project="${3:-}"

    local JSON_EVENT=$(cat <<EOF
{
  "id": "1",
  "step": "$step",
  "status": "$status",
  "project": "$project",
  "event.provider": "azure-workshop-provisioning",
  "event.category": "azure-workshop",
  "user": "$EMAIL",
  "event.type": "provisioning-step",
  "DT_ENVIRONMENT_ID": "$DT_ENVIRONMENT_ID",
  "setup_type": "$SETUP_TYPE"
}
EOF
)
    curl -s -X POST "$EVENT_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "$JSON_EVENT" > /dev/null 2>&1
}

print_status() {
    local status="$1"
    local message="$2"

    if [ "$status" == "ok" ]; then
        echo "  [OK] $message"
    elif [ "$status" == "fail" ]; then
        echo "  [FAILED] $message"
    elif [ "$status" == "info" ]; then
        echo "  [..] $message"
    else
        echo "       $message"
    fi
}

# =============================================================================
# Settings 2.0 API Functions
# =============================================================================

# Apply a Settings 2.0 configuration
applySettings20() {
    local config_name="$1"
    local json_payload="$2"

    print_status "info" "Applying Settings 2.0: $config_name"

    local response=$(curl -s -X POST \
        "$DT_BASEURL/api/v2/settings/objects?Api-Token=$DT_API_TOKEN" \
        -H 'Content-Type: application/json' \
        -H 'cache-control: no-cache' \
        -d "$json_payload")

    local error=$(echo "$response" | jq -r '.error.message // empty')
    if [ -n "$error" ]; then
        # Check if it's a "already exists" error - that's OK
        if echo "$response" | grep -q "already exists"; then
            print_status "ok" "$config_name (already exists)"
            return 0
        fi
        print_status "fail" "$config_name: $error"
        if [ "$VERBOSE" = true ]; then
            echo "       Response: $response"
        fi
        return 1
    else
        print_status "ok" "$config_name"
        return 0
    fi
}

# Configure auto-tagging rules
configureAutoTags() {
    send_event "07-WorkshopConfig-AutoTags" "running"
    echo ""
    echo "--- Configuring Auto-Tags ---"

    local RESULT=0

    # Auto-tag: project
    applySettings20 "auto-tag-project" '[{
        "schemaId": "builtin:tags.auto-tagging",
        "scope": "environment",
        "value": {
            "name": "project",
            "rules": [{
                "type": "ME",
                "enabled": true,
                "valueNormalization": "Leave text as-is",
                "attributeRule": {
                    "entityType": "PROCESS_GROUP",
                    "pgToHostPropagation": true,
                    "pgToServicePropagation": true,
                    "conditions": [{
                        "key": "PROCESS_GROUP_NAME",
                        "operator": "EXISTS"
                    }]
                }
            }]
        }
    }]' || RESULT=1

    # Auto-tag: service
    applySettings20 "auto-tag-service" '[{
        "schemaId": "builtin:tags.auto-tagging",
        "scope": "environment",
        "value": {
            "name": "service",
            "rules": [{
                "type": "ME",
                "enabled": true,
                "valueNormalization": "Leave text as-is",
                "attributeRule": {
                    "entityType": "SERVICE",
                    "serviceToHostPropagation": false,
                    "serviceToPGPropagation": true,
                    "conditions": [{
                        "key": "SERVICE_DETECTED_NAME",
                        "operator": "EXISTS"
                    }]
                }
            }]
        }
    }]' || RESULT=1

    if [ $RESULT -eq 0 ]; then
        send_event "07-WorkshopConfig-AutoTags" "success"
    else
        send_event "07-WorkshopConfig-AutoTags" "failed"
    fi

    return $RESULT
}

# Configure management zones
configureManagementZones() {
    send_event "07-WorkshopConfig-ManagementZones" "running"
    echo ""
    echo "--- Configuring Management Zones ---"

    local RESULT=0

    # Management Zone: EasyTrade
    applySettings20 "mz-easytrade" '[{
        "schemaId": "builtin:management-zones",
        "scope": "environment",
        "value": {
            "name": "EasyTrade",
            "rules": [{
                "type": "ME",
                "enabled": true,
                "entitySelector": "type(PROCESS_GROUP),tag(\"[Kubernetes]namespace:easytrade\")"
            }]
        }
    }]' || RESULT=1

    if [ $RESULT -eq 0 ]; then
        send_event "07-WorkshopConfig-ManagementZones" "success"
    else
        send_event "07-WorkshopConfig-ManagementZones" "failed"
    fi

    return $RESULT
}

# Enable Kubernetes App Experience
enableKubernetesAppExperience() {
    send_event "07-WorkshopConfig-K8sExperience" "running"
    echo ""
    echo "--- Enabling Kubernetes App Experience ---"

    applySettings20 "k8s-app-experience" '[{
        "schemaId": "builtin:app-transition.kubernetes",
        "scope": "environment",
        "value": {
            "enableKubernetesApp": true
        }
    }]'

    local RESULT=$?
    if [ $RESULT -eq 0 ]; then
        send_event "07-WorkshopConfig-K8sExperience" "success"
    else
        send_event "07-WorkshopConfig-K8sExperience" "failed"
    fi

    return $RESULT
}

# =============================================================================
# Monaco v2 Functions (Classic API only)
# =============================================================================

download_monaco() {
    send_event "06-WorkshopConfig-Download-Monaco" "running"

    # Determine OS and architecture for Monaco v2 binary
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$OS" in
        darwin)
            if [ "$ARCH" == "arm64" ]; then
                MONACO_BINARY="monaco-darwin-arm64"
            else
                MONACO_BINARY="monaco-darwin-amd64"
            fi
            ;;
        linux)
            if [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then
                MONACO_BINARY="monaco-linux-arm64"
            else
                MONACO_BINARY="monaco-linux-amd64"
            fi
            ;;
        *)
            MONACO_BINARY="monaco-linux-amd64"
            ;;
    esac

    print_status "info" "Downloading Monaco v$MONACO_V2_VERSION ($MONACO_BINARY)..."
    rm -f monaco

    wget -q -O monaco "https://github.com/Dynatrace/dynatrace-configuration-as-code/releases/download/v${MONACO_V2_VERSION}/${MONACO_BINARY}" 2>/dev/null
    chmod +x monaco

    if [ -f monaco ] && [ -x monaco ]; then
        print_status "ok" "Monaco v$MONACO_V2_VERSION installed"
        send_event "06-WorkshopConfig-Download-Monaco" "success"
    else
        print_status "fail" "Failed to download Monaco"
        send_event "06-WorkshopConfig-Download-Monaco" "failed"
        return 1
    fi
}

run_monaco() {
    local MONACO_PROJECT=$1
    local DASHBOARD_OWNER=$2

    # Set OWNER env var for dashboard project
    if [ -z "$DASHBOARD_OWNER" ]; then
        export OWNER=DUMMY_PLACEHOLDER
    else
        export OWNER=$DASHBOARD_OWNER
    fi

    # Monaco v2 uses manifest.yaml and environment variables for credentials
    export DT_BASEURL=$DT_BASEURL
    export DT_API_TOKEN=$DT_API_TOKEN

    send_event "08-WorkshopConfig-Run-Monaco" "running" "$MONACO_PROJECT"

    if [ "$VERBOSE" = true ]; then
        ./monaco deploy $MONACO_V2_MANIFEST --project $MONACO_PROJECT
        DEPLOY_RESULT=$?
    else
        ./monaco deploy $MONACO_V2_MANIFEST --project $MONACO_PROJECT > "$MONACO_LOG_FILE" 2>&1
        DEPLOY_RESULT=$?
    fi

    if [ $DEPLOY_RESULT -eq 0 ]; then
        send_event "08-WorkshopConfig-Run-Monaco" "success" "$MONACO_PROJECT"
    else
        send_event "08-WorkshopConfig-Run-Monaco" "failed" "$MONACO_PROJECT"
        if [ "$VERBOSE" = false ]; then
            echo "       Error details (use --verbose for full output):"
            grep -E "level=ERROR" "$MONACO_LOG_FILE" | head -5 | sed 's/^/       /'
        fi
    fi

    return $DEPLOY_RESULT
}

run_monaco_with_retry() {
    local MONACO_PROJECT=$1
    local DASHBOARD_OWNER=$2
    local MAX_RETRIES=${3:-2}
    local RETRY_DELAY=${4:-10}

    print_status "info" "Deploying Monaco project: $MONACO_PROJECT"

    for ((i=1; i<=MAX_RETRIES; i++)); do
        run_monaco "$MONACO_PROJECT" "$DASHBOARD_OWNER"
        RESULT=$?

        if [ $RESULT -eq 0 ]; then
            print_status "ok" "Monaco project '$MONACO_PROJECT' deployed"
            return 0
        else
            if [ $i -lt $MAX_RETRIES ]; then
                print_status "info" "Retrying in ${RETRY_DELAY}s... (attempt $((i+1))/$MAX_RETRIES)"
                sleep $RETRY_DELAY
            fi
        fi
    done

    print_status "fail" "Monaco project '$MONACO_PROJECT' failed after $MAX_RETRIES attempts"
    return 1
}

run_monaco_classic_configs() {
    local RESULT=0

    echo ""
    echo "--- Monaco: Classic API Deployment ---"

    # Deploy k8 conditional naming
    run_monaco_with_retry k8 || RESULT=1

    # Deploy EasyTrade custom service
    run_monaco_with_retry easytrade || RESULT=1

    return $RESULT
}

# =============================================================================
# Custom Dynatrace Config (Direct API)
# =============================================================================

run_custom_dynatrace_config() {
    send_event "09-WorkshopConfig-Custom-Config" "running"

    echo ""
    echo "--- Custom Dynatrace Settings (Direct API) ---"
    print_status "info" "Applying custom Dynatrace settings..."

    setFrequentIssueDetectionOff > /dev/null 2>&1
    setServiceAnomalyDetection ./custom/service-anomalydetection.json > /dev/null 2>&1

    print_status "ok" "Frequent issue detection disabled"
    print_status "ok" "Service anomaly detection configured"

    send_event "09-WorkshopConfig-Custom-Config" "success"
}

# =============================================================================
# Main Script
# =============================================================================

# Send start event
send_event "05-WorkshopConfig-Start" "running"

echo ""
echo "==========================================================================="
echo " Dynatrace Workshop Configuration"
echo "==========================================================================="
echo " Environment : $DT_BASEURL"
echo " Setup Type  : ${SETUP_TYPE:-full workshop}"
echo " Tools       : Monaco v$MONACO_V2_VERSION + Settings 2.0 API"
echo " Started     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================================================="
echo ""

OVERALL_RESULT=0

case "$SETUP_TYPE" in
    "synthetics")
        echo "Configuring Synthetic monitors only..."
        if download_monaco; then
            run_monaco synthetics || OVERALL_RESULT=1
        else
            OVERALL_RESULT=1
        fi
        ;;
    "dashboard")
        if [ -z "$DASHBOARD_OWNER_EMAIL" ]; then
            echo "ERROR: Dashboard owner email is required"
            echo "Usage: ./setup-workshop-config.sh dashboard name@company.com"
            exit 1
        fi
        echo "Configuring Dashboard for $DASHBOARD_OWNER_EMAIL..."
        if download_monaco; then
            run_monaco db "$DASHBOARD_OWNER_EMAIL" || OVERALL_RESULT=1
        else
            OVERALL_RESULT=1
        fi
        ;;
    *)
        # Full workshop configuration
        echo "Configuring full workshop..."
        echo ""

        # Step 1: Download Monaco
        echo "=== Step 1: Downloading Tools ==="
        download_monaco || OVERALL_RESULT=1

        if [ $OVERALL_RESULT -eq 0 ]; then
            # Step 2: Configure Settings 2.0 via API
            echo ""
            echo "=== Step 2: Settings 2.0 Configuration (API) ==="
            configureAutoTags || OVERALL_RESULT=1
            configureManagementZones || OVERALL_RESULT=1
            enableKubernetesAppExperience || OVERALL_RESULT=1

            # Step 3: Deploy Monaco Classic API configs
            echo ""
            echo "=== Step 3: Monaco Deployment (Classic API) ==="
            run_monaco_classic_configs || OVERALL_RESULT=1

            # Step 4: Apply custom Dynatrace settings
            echo ""
            echo "=== Step 4: Custom Dynatrace Settings ==="
            run_custom_dynatrace_config
        fi
        ;;
esac

echo ""
echo "==========================================================================="
if [ $OVERALL_RESULT -eq 0 ]; then
    echo " Status      : SUCCESS"
    send_event "10-WorkshopConfig-Complete" "success"
else
    echo " Status      : COMPLETED WITH ERRORS (check output above)"
    send_event "10-WorkshopConfig-Complete" "failed"
fi
echo " Finished    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================================================="

# Cleanup temp files
rm -f "$MONACO_LOG_FILE" 2>/dev/null

exit $OVERALL_RESULT
