#!/bin/bash

# =============================================================================
# Workshop Configuration Script - Monaco v2
# =============================================================================
# This script uses Monaco v2 (2.28.1+) for Dynatrace configuration deployment.
#
# Usage: ./setup-workshop-config.sh [setup-type] [options]
#   setup-type: k8, services-vm, synthetics, dashboard, easytrade, or blank for base
#   options: --verbose for detailed Monaco output
# =============================================================================

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

# Monaco v2 configuration
MONACO_V2_MANIFEST=./monaco-v2/manifest.yaml
MONACO_V2_VERSION="2.28.1"
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
# Monaco v2 Functions
# =============================================================================

download_monaco() {
    send_event "07-WorkshopConfig-Download-Monaco" "running"

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
        send_event "07-WorkshopConfig-Download-Monaco" "success"
    else
        print_status "fail" "Failed to download Monaco"
        send_event "07-WorkshopConfig-Download-Monaco" "failed"
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

    # Set default project
    if [ -z "$MONACO_PROJECT" ]; then
        MONACO_PROJECT=workshop
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

    print_status "info" "Deploying project: $MONACO_PROJECT"

    for ((i=1; i<=MAX_RETRIES; i++)); do
        run_monaco "$MONACO_PROJECT" "$DASHBOARD_OWNER"
        RESULT=$?

        if [ $RESULT -eq 0 ]; then
            print_status "ok" "Project '$MONACO_PROJECT' deployed successfully"
            return 0
        else
            if [ $i -lt $MAX_RETRIES ]; then
                print_status "info" "Retrying in ${RETRY_DELAY}s... (attempt $((i+1))/$MAX_RETRIES)"
                sleep $RETRY_DELAY
            fi
        fi
    done

    print_status "fail" "Project '$MONACO_PROJECT' deployment failed after $MAX_RETRIES attempts"
    return 1
}

run_custom_dynatrace_config() {
    send_event "09-WorkshopConfig-Custom-Config" "running"

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
send_event "06-WorkshopConfig-Start" "running"

echo ""
echo "==========================================================================="
echo " Dynatrace Workshop Configuration"
echo "==========================================================================="
echo " Environment : $DT_BASEURL"
echo " Setup Type  : ${SETUP_TYPE:-base workshop}"
echo " Started     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================================================="
echo ""

OVERALL_RESULT=0

case "$SETUP_TYPE" in
    "k8")
        echo "Configuring Kubernetes monitoring..."
        download_monaco && run_monaco_with_retry k8 || OVERALL_RESULT=1
        ;;
    "services-vm")
        echo "Configuring VM services..."
        download_monaco && run_monaco_with_retry services-vm || OVERALL_RESULT=1
        ;;
    "synthetics")
        echo "Configuring Synthetic monitors..."
        download_monaco && run_monaco synthetics || OVERALL_RESULT=1
        ;;
    "dashboard")
        if [ -z "$DASHBOARD_OWNER_EMAIL" ]; then
            echo "ERROR: Dashboard owner email is required"
            echo "Usage: ./setup-workshop-config.sh dashboard name@company.com"
            exit 1
        fi
        echo "Configuring Dashboard for $DASHBOARD_OWNER_EMAIL..."
        download_monaco && run_monaco db "$DASHBOARD_OWNER_EMAIL" || OVERALL_RESULT=1
        ;;
    "easytrade")
        echo "Configuring EasyTrade application..."
        download_monaco && run_monaco_with_retry easytrade || OVERALL_RESULT=1
        ;;
    *)
        echo "Configuring base workshop + EasyTrade..."
        echo ""
        if download_monaco; then
            run_monaco_with_retry workshop || OVERALL_RESULT=1
            run_monaco_with_retry easytrade || OVERALL_RESULT=1
            run_custom_dynatrace_config
        else
            OVERALL_RESULT=1
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
