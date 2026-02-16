#!/bin/bash

# =============================================================================
# Workshop Cleanup Script - Removes all workshop configurations
# =============================================================================
# This script removes:
#   - Auto-tags (project, service, stage)
#   - Management Zones (dt-orders-monolith, dt-orders-k8, dt-orders-services, EasyTrade)
#   - Monaco v2 configurations (bizevents, oneagent-features)
#   - Workshop notebooks
#
# Authentication: Platform Token
# =============================================================================

cd "$(dirname "$0")"

source ./_workshop-config.lib

# Colors
YLW='\033[1;33m'
RED='\033[0;31m'
GRN='\033[0;32m'
NC='\033[0m'

# =============================================================================
# Helper Functions
# =============================================================================

print_status() {
    local status="$1"
    local message="$2"

    if [ "$status" == "ok" ]; then
        echo -e "  ${GRN}[OK]${NC} $message"
    elif [ "$status" == "fail" ]; then
        echo -e "  ${RED}[FAILED]${NC} $message"
    elif [ "$status" == "info" ]; then
        echo "  [..] $message"
    elif [ "$status" == "skip" ]; then
        echo -e "  ${YLW}[SKIP]${NC} $message"
    else
        echo "       $message"
    fi
}

# Delete settings object by schema and name
delete_settings_by_name() {
    local schema="$1"
    local name="$2"

    print_status "info" "Deleting $schema: $name"

    # Find the object ID by name
    local response=$(curl -s \
        "$DT_BASEURL_PLATFORM/platform/classic/environment-api/v2/settings/objects?schemaIds=$schema&scopes=environment&fields=objectId,value" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN" \
        -H "Content-Type: application/json")

    # Extract object ID where value.name matches
    local object_id=$(echo "$response" | jq -r --arg name "$name" '.items[] | select(.value.name == $name) | .objectId' 2>/dev/null)

    if [ -z "$object_id" ] || [ "$object_id" == "null" ]; then
        print_status "skip" "$name (not found)"
        return 0
    fi

    # Delete the object
    local delete_response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE "$DT_BASEURL_PLATFORM/platform/classic/environment-api/v2/settings/objects/$object_id" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN")

    if [ "$delete_response" == "204" ] || [ "$delete_response" == "200" ]; then
        print_status "ok" "$name"
        return 0
    else
        print_status "fail" "$name (HTTP $delete_response)"
        return 1
    fi
}

# Delete notebook by name
delete_notebook() {
    local name="$1"

    print_status "info" "Deleting notebook: $name"

    # Find the document ID by name
    local encoded_name=$(echo "$name" | jq -sRr @uri)
    local response=$(curl -s \
        "${DT_BASEURL_PLATFORM}/platform/document/v1/documents?filter=name%3D%3D%27${encoded_name}%27%26type%3D%3D%27notebook%27" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN")

    local doc_id=$(echo "$response" | jq -r '.documents[0].id // empty')

    if [ -z "$doc_id" ] || [ "$doc_id" == "null" ]; then
        print_status "skip" "$name (not found)"
        return 0
    fi

    # Delete the document
    local delete_response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X DELETE "${DT_BASEURL_PLATFORM}/platform/document/v1/documents/$doc_id" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN")

    if [ "$delete_response" == "204" ] || [ "$delete_response" == "200" ]; then
        print_status "ok" "$name"
        return 0
    else
        print_status "fail" "$name (HTTP $delete_response)"
        return 1
    fi
}

# Delete bizevents capture rules by name pattern
delete_bizevents_rules() {
    print_status "info" "Finding EasyTrade bizevent rules..."

    local response=$(curl -s \
        "$DT_BASEURL_PLATFORM/platform/classic/environment-api/v2/settings/objects?schemaIds=builtin:bizevents.http.incoming&scopes=environment&fields=objectId,value" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN" \
        -H "Content-Type: application/json")

    # Find all EasyTrade rules
    local object_ids=$(echo "$response" | jq -r '.items[] | select(.value.ruleName | test("EasyTrade"; "i")) | .objectId' 2>/dev/null)

    if [ -z "$object_ids" ]; then
        print_status "skip" "No EasyTrade bizevent rules found"
        return 0
    fi

    local count=0
    for object_id in $object_ids; do
        local delete_response=$(curl -s -o /dev/null -w "%{http_code}" \
            -X DELETE "$DT_BASEURL_PLATFORM/platform/classic/environment-api/v2/settings/objects/$object_id" \
            -H "Authorization: Bearer $DT_PLATFORM_TOKEN")

        if [ "$delete_response" == "204" ] || [ "$delete_response" == "200" ]; then
            ((count++))
        fi
    done

    print_status "ok" "Deleted $count bizevent rules"
}

# Delete OneAgent feature settings for bizevents
delete_oneagent_features() {
    print_status "info" "Finding OneAgent bizevent features..."

    local response=$(curl -s \
        "$DT_BASEURL_PLATFORM/platform/classic/environment-api/v2/settings/objects?schemaIds=builtin:oneagent.features&scopes=environment&fields=objectId,value" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN" \
        -H "Content-Type: application/json")

    # Find all SENSOR_*_BIZEVENTS_HTTP_INCOMING features
    local object_ids=$(echo "$response" | jq -r '.items[] | select(.value.key | test("BIZEVENTS"; "i")) | .objectId' 2>/dev/null)

    if [ -z "$object_ids" ]; then
        print_status "skip" "No OneAgent bizevent features found"
        return 0
    fi

    local count=0
    for object_id in $object_ids; do
        local delete_response=$(curl -s -o /dev/null -w "%{http_code}" \
            -X DELETE "$DT_BASEURL_PLATFORM/platform/classic/environment-api/v2/settings/objects/$object_id" \
            -H "Authorization: Bearer $DT_PLATFORM_TOKEN")

        if [ "$delete_response" == "204" ] || [ "$delete_response" == "200" ]; then
            ((count++))
        fi
    done

    print_status "ok" "Deleted $count OneAgent features"
}

# =============================================================================
# Main Script
# =============================================================================

echo ""
echo "==========================================================================="
echo -e "${YLW}Workshop Cleanup - Remove Dynatrace Configurations${NC}"
echo "==========================================================================="
echo ""
echo "Environment: $DT_BASEURL_PLATFORM"
echo ""
echo "This will delete:"
echo "  - Auto-tags: project, service, stage"
echo "  - Management Zones: dt-orders-monolith, dt-orders-k8, dt-orders-services, EasyTrade"
echo "  - EasyTrade bizevent capture rules"
echo "  - OneAgent bizevent features"
echo "  - Workshop notebooks"
echo ""
echo "==========================================================================="

# Allow bypass with argument
if [ -z "$1" ]; then
    read -p "Proceed with cleanup? (y/n) : " REPLY
else
    REPLY=$1
fi

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""

# -----------------------------------------------------------------------------
# Delete Auto-Tags
# -----------------------------------------------------------------------------
echo "--- Deleting Auto-Tags ---"
delete_settings_by_name "builtin:tags.auto-tagging" "project"
delete_settings_by_name "builtin:tags.auto-tagging" "service"
delete_settings_by_name "builtin:tags.auto-tagging" "stage"
echo ""

# -----------------------------------------------------------------------------
# Delete Management Zones
# -----------------------------------------------------------------------------
echo "--- Deleting Management Zones ---"
delete_settings_by_name "builtin:management-zones" "dt-orders-monolith"
delete_settings_by_name "builtin:management-zones" "dt-orders-k8"
delete_settings_by_name "builtin:management-zones" "dt-orders-services"
delete_settings_by_name "builtin:management-zones" "EasyTrade"
echo ""

# -----------------------------------------------------------------------------
# Delete Bizevent Rules
# -----------------------------------------------------------------------------
echo "--- Deleting Bizevent Capture Rules ---"
delete_bizevents_rules
echo ""

# -----------------------------------------------------------------------------
# Delete OneAgent Features (if permission allows)
# -----------------------------------------------------------------------------
echo "--- Deleting OneAgent Bizevent Features ---"
delete_oneagent_features
echo ""

# -----------------------------------------------------------------------------
# Delete Notebooks
# -----------------------------------------------------------------------------
echo "--- Deleting Workshop Notebooks ---"

# YAML notebooks (from dtctl)
delete_notebook "Azure Workshop - Log Analysis"

# JSON notebooks (from Documents API)
delete_notebook "Logs-Lab"
delete_notebook "Logs-Answers"
delete_notebook "Metrics-Lab"
delete_notebook "Metrics-Answers"
delete_notebook "BizEvents-Lab"
delete_notebook "BizEvents-Answers"
echo ""

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "==========================================================================="
echo -e "${GRN}Cleanup Complete${NC}"
echo "==========================================================================="
echo ""
echo "Note: Some settings like K8s App Experience and Vulnerability Analytics"
echo "      are left unchanged as they may be used by other applications."
echo ""
