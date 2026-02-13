#!/bin/bash

# =============================================================================
# Workshop Configuration Script - dtctl + Monaco
# =============================================================================
# This script uses:
#   - dtctl for Settings 2.0 and SLOs (auto-tags, management-zones, etc.)
#   - Monaco v2 for Classic API configs (custom-services, synthetics, dashboards)
#
# Usage: ./setup-workshop-config.sh [setup-type] [options]
#   setup-type: synthetics, dashboard, or blank for full workshop config
#   options: --verbose for detailed output
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

# Tool versions
DTCTL_VERSION="0.18.0"
MONACO_V2_VERSION="2.28.1"

# Configuration paths
DTCTL_DIR=./dtctl
MONACO_V2_MANIFEST=./monaco-v2/manifest.yaml

# Log files
DTCTL_LOG_FILE="/tmp/dtctl-deploy-$$.log"
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
# dtctl Functions (Settings 2.0 + SLOs)
# =============================================================================

download_dtctl() {
    send_event "07-WorkshopConfig-Download-dtctl" "running"

    # Determine OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$OS" in
        darwin)
            if [ "$ARCH" == "arm64" ]; then
                DTCTL_BINARY="dtctl_darwin_arm64"
            else
                DTCTL_BINARY="dtctl_darwin_amd64"
            fi
            ;;
        linux)
            if [ "$ARCH" == "aarch64" ] || [ "$ARCH" == "arm64" ]; then
                DTCTL_BINARY="dtctl_linux_arm64"
            else
                DTCTL_BINARY="dtctl_linux_amd64"
            fi
            ;;
        *)
            DTCTL_BINARY="dtctl_linux_amd64"
            ;;
    esac

    print_status "info" "Downloading dtctl v$DTCTL_VERSION ($DTCTL_BINARY)..."
    rm -f dtctl-bin

    wget -q -O dtctl-bin "https://github.com/dynatrace-oss/dtctl/releases/download/v${DTCTL_VERSION}/${DTCTL_BINARY}" 2>/dev/null
    chmod +x dtctl-bin

    if [ -f dtctl-bin ] && [ -x dtctl-bin ]; then
        print_status "ok" "dtctl v$DTCTL_VERSION installed"
        send_event "07-WorkshopConfig-Download-dtctl" "success"
        return 0
    else
        print_status "fail" "Failed to download dtctl"
        send_event "07-WorkshopConfig-Download-dtctl" "failed"
        return 1
    fi
}

deploy_dtctl_settings() {
    local settings_file="$1"
    local config_name="$2"

    send_event "08-WorkshopConfig-dtctl-Settings" "running" "$config_name"
    print_status "info" "Deploying Settings: $config_name"

    if [ "$VERBOSE" = true ]; then
        ./dtctl-bin config apply -f "$settings_file" \
            --url "$DT_BASEURL" \
            --api-token "$DT_API_TOKEN"
        DEPLOY_RESULT=$?
    else
        ./dtctl-bin config apply -f "$settings_file" \
            --url "$DT_BASEURL" \
            --api-token "$DT_API_TOKEN" > "$DTCTL_LOG_FILE" 2>&1
        DEPLOY_RESULT=$?
    fi

    if [ $DEPLOY_RESULT -eq 0 ]; then
        print_status "ok" "Settings deployed: $config_name"
        send_event "08-WorkshopConfig-dtctl-Settings" "success" "$config_name"
    else
        print_status "fail" "Settings failed: $config_name"
        send_event "08-WorkshopConfig-dtctl-Settings" "failed" "$config_name"
        if [ "$VERBOSE" = false ] && [ -f "$DTCTL_LOG_FILE" ]; then
            echo "       Error details (use --verbose for full output):"
            tail -5 "$DTCTL_LOG_FILE" | sed 's/^/       /'
        fi
    fi

    return $DEPLOY_RESULT
}

deploy_dtctl_slos() {
    local slo_file="$1"

    send_event "08-WorkshopConfig-dtctl-SLOs" "running"
    print_status "info" "Deploying SLOs"

    if [ "$VERBOSE" = true ]; then
        ./dtctl-bin slo apply -f "$slo_file" \
            --url "$DT_BASEURL" \
            --api-token "$DT_API_TOKEN"
        DEPLOY_RESULT=$?
    else
        ./dtctl-bin slo apply -f "$slo_file" \
            --url "$DT_BASEURL" \
            --api-token "$DT_API_TOKEN" > "$DTCTL_LOG_FILE" 2>&1
        DEPLOY_RESULT=$?
    fi

    if [ $DEPLOY_RESULT -eq 0 ]; then
        print_status "ok" "SLOs deployed successfully"
        send_event "08-WorkshopConfig-dtctl-SLOs" "success"
    else
        print_status "fail" "SLO deployment failed"
        send_event "08-WorkshopConfig-dtctl-SLOs" "failed"
        if [ "$VERBOSE" = false ] && [ -f "$DTCTL_LOG_FILE" ]; then
            echo "       Error details (use --verbose for full output):"
            tail -5 "$DTCTL_LOG_FILE" | sed 's/^/       /'
        fi
    fi

    return $DEPLOY_RESULT
}

run_dtctl_full_deployment() {
    local RESULT=0

    echo ""
    echo "--- dtctl: Settings 2.0 Deployment ---"

    # Deploy auto-tags
    deploy_dtctl_settings "$DTCTL_DIR/settings/auto-tags.yaml" "auto-tags" || RESULT=1

    # Deploy management zones
    deploy_dtctl_settings "$DTCTL_DIR/settings/management-zones.yaml" "management-zones" || RESULT=1

    # Deploy Kubernetes experience
    deploy_dtctl_settings "$DTCTL_DIR/settings/kubernetes-experience.yaml" "kubernetes-experience" || RESULT=1

    # Deploy Vulnerability Analytics
    deploy_dtctl_settings "$DTCTL_DIR/settings/vulnerability-analytics.yaml" "vulnerability-analytics" || RESULT=1

    echo ""
    echo "--- dtctl: SLO Deployment ---"

    # Deploy SLOs
    deploy_dtctl_slos "$DTCTL_DIR/slos/slos.yaml" || RESULT=1

    return $RESULT
}

# =============================================================================
# Monaco v2 Functions (Classic API only)
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

    # Monaco v2 uses manifest.yaml and environment variables for credentials
    export DT_BASEURL=$DT_BASEURL
    export DT_API_TOKEN=$DT_API_TOKEN

    send_event "09-WorkshopConfig-Run-Monaco" "running" "$MONACO_PROJECT"

    if [ "$VERBOSE" = true ]; then
        ./monaco deploy $MONACO_V2_MANIFEST --project $MONACO_PROJECT
        DEPLOY_RESULT=$?
    else
        ./monaco deploy $MONACO_V2_MANIFEST --project $MONACO_PROJECT > "$MONACO_LOG_FILE" 2>&1
        DEPLOY_RESULT=$?
    fi

    if [ $DEPLOY_RESULT -eq 0 ]; then
        send_event "09-WorkshopConfig-Run-Monaco" "success" "$MONACO_PROJECT"
    else
        send_event "09-WorkshopConfig-Run-Monaco" "failed" "$MONACO_PROJECT"
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
    send_event "10-WorkshopConfig-Custom-Config" "running"

    echo ""
    echo "--- Custom Dynatrace Settings (Direct API) ---"
    print_status "info" "Applying custom Dynatrace settings..."

    setFrequentIssueDetectionOff > /dev/null 2>&1
    setServiceAnomalyDetection ./custom/service-anomalydetection.json > /dev/null 2>&1

    print_status "ok" "Frequent issue detection disabled"
    print_status "ok" "Service anomaly detection configured"

    send_event "10-WorkshopConfig-Custom-Config" "success"
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
echo " Setup Type  : ${SETUP_TYPE:-full workshop}"
echo " Tools       : dtctl v$DTCTL_VERSION + Monaco v$MONACO_V2_VERSION"
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
        echo "Configuring full workshop (dtctl + Monaco)..."
        echo ""

        # Step 1: Download tools
        echo "=== Step 1: Downloading Tools ==="
        download_dtctl || OVERALL_RESULT=1
        download_monaco || OVERALL_RESULT=1

        if [ $OVERALL_RESULT -eq 0 ]; then
            # Step 2: Deploy dtctl Settings 2.0 + SLOs
            echo ""
            echo "=== Step 2: dtctl Deployment (Settings + SLOs) ==="
            run_dtctl_full_deployment || OVERALL_RESULT=1

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
    send_event "11-WorkshopConfig-Complete" "success"
else
    echo " Status      : COMPLETED WITH ERRORS (check output above)"
    send_event "11-WorkshopConfig-Complete" "failed"
fi
echo " Finished    : $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================================================="

# Cleanup temp files
rm -f "$DTCTL_LOG_FILE" "$MONACO_LOG_FILE" 2>/dev/null

exit $OVERALL_RESULT
