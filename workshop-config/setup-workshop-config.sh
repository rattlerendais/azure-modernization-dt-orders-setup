#!/bin/bash

# =============================================================================
# Workshop Configuration Script - Monaco + dtctl (Platform Token)
# =============================================================================
# This script uses:
#   - Monaco v2 with Platform Token for Settings 2.0 configs
#   - dtctl for notebooks and platform resources
#   - Direct Settings 2.0 API calls for additional configurations
#
# All authentication uses a single Platform Token with scopes:
#   settings:objects:read, settings:objects:write, settings:schemas:read
#   document:documents:read, document:documents:write, app-engine:apps:run
#
# Usage: ./setup-workshop-config.sh [options]
#   options: --verbose for detailed output
#            --skip-notebooks to skip notebook upload
# =============================================================================

# Change to script directory to ensure relative paths work
cd "$(dirname "$0")"

source ./_workshop-config.lib

# Parse arguments
VERBOSE=false
SKIP_NOTEBOOKS=false

for arg in "$@"; do
    case $arg in
        --verbose|-v)
            VERBOSE=true
            ;;
        --skip-notebooks)
            SKIP_NOTEBOOKS=true
            ;;
    esac
done

# Tool versions
MONACO_V2_VERSION="2.28.1"
DTCTL_VERSION="0.10.0"

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
  "DT_ENVIRONMENT_ID": "$DT_ENVIRONMENT_ID"
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
# Settings 2.0 API Functions (using Platform Token)
# =============================================================================

# Apply a Settings 2.0 configuration using Platform Token
applySettings20() {
    local config_name="$1"
    local json_payload="$2"

    print_status "info" "Applying Settings 2.0: $config_name"

    # Use Platform Token with Bearer auth against platform URL
    local response=$(curl -s -X POST \
        "$DT_BASEURL_PLATFORM/platform/classic/environment-api/v2/settings/objects" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN" \
        -H 'Content-Type: application/json' \
        -H 'cache-control: no-cache' \
        -d "$json_payload")

    # Check if response is an array (success) or object (might be error)
    local is_array=$(echo "$response" | jq -r 'if type == "array" then "yes" else "no" end' 2>/dev/null)

    if [ "$is_array" == "yes" ]; then
        # Success - API returns array of created objects
        print_status "ok" "$config_name"
        return 0
    else
        # Check for error message
        local error=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
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
            # Unknown response format, but no error - assume success
            print_status "ok" "$config_name"
            return 0
        fi
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

# Enable Vulnerability Analytics (Third-Party + Code-Level)
enableVulnerabilityAnalytics() {
    send_event "07-WorkshopConfig-VulnerabilityAnalytics" "running"
    echo ""
    echo "--- Enabling Vulnerability Analytics ---"

    applySettings20 "vulnerability-analytics" '[{
        "schemaId": "builtin:appsec.runtime-vulnerability-detection",
        "scope": "environment",
        "value": {
            "enableRuntimeVulnerabilityDetection": true,
            "globalMonitoringModeTPV": "MONITORING_ON",
            "enableCodeLevelVulnerabilityDetection": true,
            "globalMonitoringModeJava": "MONITORING_ON",
            "globalMonitoringModeDotNet": "MONITORING_ON"
        }
    }]'

    local RESULT=$?
    if [ $RESULT -eq 0 ]; then
        send_event "07-WorkshopConfig-VulnerabilityAnalytics" "success"
    else
        send_event "07-WorkshopConfig-VulnerabilityAnalytics" "failed"
    fi

    return $RESULT
}

# =============================================================================
# Monaco v2 Functions (Settings 2.0 with Platform Token)
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
        mingw*|msys*|cygwin*)
            MONACO_BINARY="monaco-windows-amd64.exe"
            ;;
        *)
            MONACO_BINARY="monaco-linux-amd64"
            ;;
    esac

    print_status "info" "Downloading Monaco v$MONACO_V2_VERSION ($MONACO_BINARY)..."
    rm -f monaco monaco.exe

    if wget -q -O monaco "https://github.com/Dynatrace/dynatrace-configuration-as-code/releases/download/v${MONACO_V2_VERSION}/${MONACO_BINARY}" 2>/dev/null || \
       curl -sL -o monaco "https://github.com/Dynatrace/dynatrace-configuration-as-code/releases/download/v${MONACO_V2_VERSION}/${MONACO_BINARY}"; then
        chmod +x monaco 2>/dev/null
        if [ -f monaco ]; then
            print_status "ok" "Monaco v$MONACO_V2_VERSION installed"
            send_event "06-WorkshopConfig-Download-Monaco" "success"
            return 0
        fi
    fi

    print_status "fail" "Failed to download Monaco"
    send_event "06-WorkshopConfig-Download-Monaco" "failed"
    return 1
}

run_monaco() {
    local MONACO_PROJECT=$1

    # Monaco v2 uses manifest.yaml and environment variables for credentials
    # Export Platform Token and URL for Monaco
    export DT_BASEURL_PLATFORM=$DT_BASEURL_PLATFORM
    export DT_PLATFORM_TOKEN=$DT_PLATFORM_TOKEN

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
            grep -iE "error|failed" "$MONACO_LOG_FILE" 2>/dev/null | head -5 | sed 's/^/       /'
        fi
    fi

    return $DEPLOY_RESULT
}

run_monaco_with_retry() {
    local MONACO_PROJECT=$1
    local MAX_RETRIES=${2:-2}
    local RETRY_DELAY=${3:-10}

    print_status "info" "Deploying Monaco project: $MONACO_PROJECT"

    for ((i=1; i<=MAX_RETRIES; i++)); do
        run_monaco "$MONACO_PROJECT"
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

run_monaco_easytrade_configs() {
    local RESULT=0

    echo ""
    echo "--- Monaco: EasyTrade Settings 2.0 Configuration ---"

    # Deploy OneAgent features for bizevent capturing (must be first)
    run_monaco_with_retry easytrade-oneagent-features || RESULT=1

    # Deploy EasyTrade business events capturing rules
    run_monaco_with_retry easytrade-bizevents || RESULT=1

    return $RESULT
}

# =============================================================================
# dtctl Functions
# =============================================================================

download_dtctl() {
    send_event "06-WorkshopConfig-Download-dtctl" "running"

    # Determine OS and architecture
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
    esac

    case "$OS" in
        darwin) OS="darwin" ;;
        linux) OS="linux" ;;
        mingw*|msys*|cygwin*) OS="windows" ;;
    esac

    local PLATFORM="${OS}_${ARCH}"
    local EXT="tar.gz"
    [ "$OS" == "windows" ] && EXT="zip"

    local DOWNLOAD_URL="https://github.com/dynatrace-oss/dtctl/releases/download/v${DTCTL_VERSION}/dtctl_${DTCTL_VERSION}_${PLATFORM}.${EXT}"

    print_status "info" "Downloading dtctl v$DTCTL_VERSION ($PLATFORM)..."
    rm -f dtctl dtctl.exe

    local TEMP_FILE="/tmp/dtctl_download.${EXT}"
    if curl -sL -o "$TEMP_FILE" "$DOWNLOAD_URL"; then
        if [ "$EXT" == "zip" ]; then
            unzip -o -q "$TEMP_FILE" dtctl.exe -d . 2>/dev/null
        else
            tar -xzf "$TEMP_FILE" dtctl 2>/dev/null
        fi
        rm -f "$TEMP_FILE"

        chmod +x dtctl 2>/dev/null

        if [ -f dtctl ] || [ -f dtctl.exe ]; then
            print_status "ok" "dtctl v$DTCTL_VERSION installed"
            send_event "06-WorkshopConfig-Download-dtctl" "success"
            return 0
        fi
    fi

    print_status "fail" "Failed to download dtctl"
    send_event "06-WorkshopConfig-Download-dtctl" "failed"
    return 1
}

configure_dtctl() {
    print_status "info" "Configuring dtctl context..."

    local DTCTL="./dtctl"
    [ -f "./dtctl.exe" ] && DTCTL="./dtctl.exe"

    # Set context
    $DTCTL config set-context workshop \
        --environment "$DT_BASEURL_PLATFORM" \
        --token-ref workshop-token \
        --safety-level readwrite-all 2>/dev/null

    # Set credentials
    $DTCTL config set-credentials workshop-token \
        --token "$DT_PLATFORM_TOKEN" 2>/dev/null

    # Use the context
    $DTCTL config use-context workshop 2>/dev/null

    print_status "ok" "dtctl configured"
}

upload_notebooks() {
    send_event "09-WorkshopConfig-Upload-Notebooks" "running"
    echo ""
    echo "--- Uploading Workshop Notebooks ---"

    local DTCTL="./dtctl"
    [ -f "./dtctl.exe" ] && DTCTL="./dtctl.exe"

    local NOTEBOOKS_DIR="./notebooks"
    local RESULT=0

    if [ ! -d "$NOTEBOOKS_DIR" ]; then
        print_status "info" "No notebooks directory found, skipping"
        return 0
    fi

    local NOTEBOOK_COUNT=$(find "$NOTEBOOKS_DIR" -name "*.yaml" -o -name "*.yml" 2>/dev/null | wc -l)
    if [ "$NOTEBOOK_COUNT" -eq 0 ]; then
        print_status "info" "No notebooks found to upload"
        return 0
    fi

    for notebook in "$NOTEBOOKS_DIR"/*.yaml "$NOTEBOOKS_DIR"/*.yml; do
        [ -e "$notebook" ] || continue

        local NOTEBOOK_NAME=$(basename "$notebook")
        print_status "info" "Uploading: $NOTEBOOK_NAME"

        if $DTCTL apply -f "$notebook" 2>/dev/null; then
            print_status "ok" "$NOTEBOOK_NAME"
        else
            print_status "fail" "$NOTEBOOK_NAME"
            ((RESULT++))
        fi
    done

    if [ $RESULT -eq 0 ]; then
        send_event "09-WorkshopConfig-Upload-Notebooks" "success"
    else
        send_event "09-WorkshopConfig-Upload-Notebooks" "failed"
    fi

    return $RESULT
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
echo " Environment : $DT_BASEURL_PLATFORM"
echo " Auth        : Platform Token"
echo " Tools       : Monaco v$MONACO_V2_VERSION + dtctl v$DTCTL_VERSION"
echo " Started     : $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================================================="
echo ""

# Verify Platform Token is available
if [ -z "$DT_PLATFORM_TOKEN" ]; then
    echo "ERROR: DT_PLATFORM_TOKEN is not set"
    echo "Make sure workshop-credentials.json contains a valid Platform Token"
    exit 1
fi

OVERALL_RESULT=0

# Full workshop configuration
echo "Configuring full workshop..."
echo ""

# Step 1: Download Tools
echo "=== Step 1: Downloading Tools ==="
download_monaco || OVERALL_RESULT=1
download_dtctl || OVERALL_RESULT=1

if [ $OVERALL_RESULT -eq 0 ]; then
    # Configure dtctl
    configure_dtctl

    # Step 2: Configure Settings 2.0 via API
    echo ""
    echo "=== Step 2: Settings 2.0 Configuration (API) ==="
    configureAutoTags || OVERALL_RESULT=1
    configureManagementZones || OVERALL_RESULT=1
    enableKubernetesAppExperience || OVERALL_RESULT=1
    enableVulnerabilityAnalytics || OVERALL_RESULT=1

    # Step 3: Deploy Monaco Settings 2.0 configs
    echo ""
    echo "=== Step 3: Monaco Deployment (Settings 2.0) ==="
    run_monaco_easytrade_configs || OVERALL_RESULT=1

    # Step 4: Upload Notebooks (optional)
    if [ "$SKIP_NOTEBOOKS" = false ]; then
        echo ""
        echo "=== Step 4: Upload Notebooks (dtctl) ==="
        upload_notebooks || OVERALL_RESULT=1
    else
        echo ""
        echo "=== Step 4: Upload Notebooks (SKIPPED) ==="
    fi
fi

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
echo ""
echo "View notebooks: $DT_BASEURL_PLATFORM/ui/document/list?filter-documentType=notebook"
echo ""

# Cleanup temp files
rm -f "$MONACO_LOG_FILE" 2>/dev/null

exit $OVERALL_RESULT
