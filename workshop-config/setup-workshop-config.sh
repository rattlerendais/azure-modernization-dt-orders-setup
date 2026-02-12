#!/bin/bash

# =============================================================================
# Workshop Configuration Script - Monaco v2
# =============================================================================
# This script uses Monaco v2 (2.28.1+) for Dynatrace configuration deployment.
#
# Monaco v2 improvements over v1:
# - Better dependency resolution between configs
# - Manifest-based configuration (manifest.yaml instead of environments.yaml)
# - Built-in retry logic for transient failures
# - Support for Settings 2.0 APIs
# =============================================================================

source ./_workshop-config.lib

# optional argument.  If not passed, then the base workshop is setup.
# setup types are for additional features like kubernetes
SETUP_TYPE=$1
DASHBOARD_OWNER_EMAIL=$2    # This is required for the dashboard monaco project
                            # Otherwise it is not required

# Monaco v2 configuration
MONACO_V2_MANIFEST=./monaco-v2/manifest.yaml
MONACO_V2_VERSION="2.28.1"

# =============================================================================
# Monaco v2 Functions
# =============================================================================

download_monaco() {
    PROVISIONING_STEP="07-WorkshopConfig-Download-Monaco"
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
            # Default to Linux amd64
            MONACO_BINARY="monaco-linux-amd64"
            ;;
    esac

    echo "Getting Monaco v2 binary: $MONACO_BINARY (version $MONACO_V2_VERSION)"
    rm -f monaco

    # Monaco v2 is from the dynatrace/dynatrace-configuration-as-code repo
    wget -q -O monaco "https://github.com/Dynatrace/dynatrace-configuration-as-code/releases/download/v${MONACO_V2_VERSION}/${MONACO_BINARY}"
    chmod +x monaco

    echo "Installed Monaco Version: $(./monaco version 2>/dev/null || ./monaco --version | tail -1)"

    DT_SEND_EVENT=$(curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT")
}

run_monaco() {
    MONACO_PROJECT=$1
    DASHBOARD_OWNER=$2
    PROVISIONING_STEP="08-WorkshopConfig-Run-Monaco"
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

    echo "Running Monaco v2 for project = $MONACO_PROJECT"
    echo "Command: ./monaco deploy $MONACO_V2_MANIFEST --project $MONACO_PROJECT"

    # Monaco v2 uses manifest.yaml and environment variables for credentials
    export DT_BASEURL=$DT_BASEURL
    export DT_API_TOKEN=$DT_API_TOKEN

    ./monaco deploy $MONACO_V2_MANIFEST --project $MONACO_PROJECT

    DEPLOY_RESULT=$?

    DT_SEND_EVENT=$(curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT")

    return $DEPLOY_RESULT
}

run_monaco_with_retry() {
    MONACO_PROJECT=$1
    DASHBOARD_OWNER=$2
    MAX_RETRIES=${3:-2}
    RETRY_DELAY=${4:-10}

    echo "Running Monaco v2 with retry logic (max $MAX_RETRIES attempts)"

    for ((i=1; i<=MAX_RETRIES; i++)); do
        echo ""
        echo "=== Attempt $i of $MAX_RETRIES ==="

        run_monaco "$MONACO_PROJECT" "$DASHBOARD_OWNER"
        RESULT=$?

        if [ $RESULT -eq 0 ]; then
            echo "Monaco deployment succeeded on attempt $i"
            return 0
        else
            if [ $i -lt $MAX_RETRIES ]; then
                echo "Deployment had issues, waiting ${RETRY_DELAY}s before retry..."
                echo "(This can happen due to Dynatrace API propagation delays)"
                sleep $RETRY_DELAY
            fi
        fi
    done

    echo "Warning: Deployment completed with potential issues after $MAX_RETRIES attempts"
    return 1
}

run_custom_dynatrace_config() {
    PROVISIONING_STEP="09-WorkshopConfig-Run-Custom-Dynatrace-Config"
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
    setFrequentIssueDetectionOff
    setServiceAnomalyDetection ./custom/service-anomalydetection.json
    DT_SEND_EVENT=$(curl -s -X POST https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event \
     -H "Content-Type: application/json" \
     -d "$JSON_EVENT")
}

# =============================================================================
# Main Script
# =============================================================================

echo ""
echo "-----------------------------------------------------------------------------------"
echo "Setting up Workshop config for type: $SETUP_TYPE"
echo "Dynatrace  : $DT_BASEURL"
echo "Starting   : $(date)"
echo "Monaco     : v2 ($MONACO_V2_VERSION)"
echo "-----------------------------------------------------------------------------------"
echo ""

case "$SETUP_TYPE" in
    "k8")
        echo "Setup type = k8"
        download_monaco
        run_monaco_with_retry k8
        ;;
    "services-vm")
        echo "Setup type = services-vm"
        download_monaco
        run_monaco_with_retry services-vm
        ;;
    "synthetics")
        echo "Setup type = synthetics"
        # Synthetics don't have dependencies, single run is fine
        run_monaco synthetics
        ;;
    "dashboard")
        if [ -z $DASHBOARD_OWNER_EMAIL ]; then
            echo "ABORT dashboard owner email is required argument"
            echo "syntax: ./setup-workshop-config.sh dashboard name@company.com"
            exit 1
        else
            echo "Setup type = dashboard"
            run_monaco db $DASHBOARD_OWNER_EMAIL
        fi
        ;;
    "easytrade")
        echo "Setup type = easytrade"
        echo "Deploying EasyTrade Monaco configuration..."
        echo "  - Management Zone: EasyTrade"
        echo "  - Custom Service: NotMiningBitcoin (.NET)"
        download_monaco
        run_monaco_with_retry easytrade
        ;;
    *)
        echo "Setup type = base workshop"
        download_monaco
        run_monaco_with_retry workshop
        run_custom_dynatrace_config
        ;;
esac

echo ""
echo "-----------------------------------------------------------------------------------"
echo "Done Setting up Workshop config for type - $SETUP_TYPE"
echo "End: $(date)"
echo "-----------------------------------------------------------------------------------"
