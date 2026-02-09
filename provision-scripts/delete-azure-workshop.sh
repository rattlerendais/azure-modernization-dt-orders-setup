#!/bin/bash

# =============================================================================
# Azure Workshop Delete Script
# Deletes all workshop resources: Resource Group, VM, AKS Cluster, AI Foundry
# Includes option to purge AI Foundry (Cognitive Services) after deletion
#
# Usage:
#   ./delete-azure-workshop.sh                # Interactive delete with prompts
#   ./delete-azure-workshop.sh --purge        # Delete AND purge AI Foundry
#   ./delete-azure-workshop.sh --check        # Check resource status only
#   ./delete-azure-workshop.sh --help         # Show all options
# =============================================================================

# Colors for output
YLW='\033[1;33m'
GRN='\033[0;32m'
RED='\033[0;31m'
BLU='\033[0;34m'
NC='\033[0m'

# Default values (matching setup script)
DEFAULT_LOCATION="eastus"
DEFAULT_RESOURCE_GROUP="dynatrace-azure-workshop"
DEFAULT_VM_NAME="dt-orders-monolith"
DEFAULT_AKS_CLUSTER_NAME="dynatrace-azure-workshop-cluster"
DEFAULT_AIFOUNDRY_NAME="dynatrace-azure-workshop-aifoundry"

# Flag for purging AI Foundry
PURGE_AIFOUNDRY=false

# Dynatrace Event Tracking (optional - set these for event tracking)
DT_EVENT_ENDPOINT="https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event"
EMAIL=""
DT_ENVIRONMENT_ID=""

# =============================================================================
# Helper Functions
# =============================================================================

# Send deletion event to Dynatrace (if EMAIL and DT_ENVIRONMENT_ID are set)
send_dt_event() {
    local step=$1
    local extra_data=${2:-""}

    # Only send if both EMAIL and DT_ENVIRONMENT_ID are set
    if [ -n "$EMAIL" ] && [ -n "$DT_ENVIRONMENT_ID" ]; then
        local JSON_EVENT='{"id":"1","step":"'"$step"'","event.provider":"azure-workshop-deletion","event.category":"azure-workshop","user":"'"$EMAIL"'","event.type":"deletion-step"'"$extra_data"',"DT_ENVIRONMENT_ID":"'"$DT_ENVIRONMENT_ID"'"}'
        curl -s -X POST "$DT_EVENT_ENDPOINT" \
            -H "Content-Type: application/json" \
            -d "$JSON_EVENT" > /dev/null 2>&1
    fi
}

print_header() {
    echo ""
    echo "==========================================================================="
    echo -e "${BLU}$1${NC}"
    echo "==========================================================================="
}

print_success() {
    echo -e "${GRN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YLW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLU}ℹ $1${NC}"
}

# =============================================================================
# Resource Existence Check Functions
# =============================================================================

check_resource_group_exists() {
    local rg_name=$1
    local subscription=$2

    RESULT=$(az group show --name "$rg_name" --subscription "$subscription" --query id --output tsv 2>&1)
    if echo "$RESULT" | grep -qE "ResourceGroupNotFound|ResourceNotFound|ERROR"; then
        echo "false"
    elif [ -n "$RESULT" ]; then
        echo "true"
    else
        echo "false"
    fi
}

check_vm_exists() {
    local vm_name=$1
    local rg_name=$2
    local subscription=$3

    RESULT=$(az vm show --name "$vm_name" --resource-group "$rg_name" --subscription "$subscription" --query id --output tsv 2>&1)
    if echo "$RESULT" | grep -qE "ResourceNotFound|ResourceGroupNotFound|ERROR"; then
        echo "false"
    elif [ -n "$RESULT" ]; then
        echo "true"
    else
        echo "false"
    fi
}

check_aks_exists() {
    local aks_name=$1
    local rg_name=$2
    local subscription=$3

    RESULT=$(az aks show --name "$aks_name" --resource-group "$rg_name" --subscription "$subscription" --query id --output tsv 2>&1)
    if echo "$RESULT" | grep -qE "ResourceNotFound|ResourceGroupNotFound|ERROR"; then
        echo "false"
    elif [ -n "$RESULT" ]; then
        echo "true"
    else
        echo "false"
    fi
}

check_aifoundry_exists() {
    local account_name=$1
    local rg_name=$2
    local subscription=$3

    RESULT=$(az cognitiveservices account show --name "$account_name" --resource-group "$rg_name" --subscription "$subscription" --query id --output tsv 2>&1)
    if echo "$RESULT" | grep -qE "ResourceNotFound|ResourceGroupNotFound|ERROR"; then
        echo "false"
    elif [ -n "$RESULT" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# Check if AI Foundry exists in deleted state (soft-deleted)
check_aifoundry_deleted() {
    local account_name=$1
    local location=$2
    local subscription=$3

    # List deleted cognitive services accounts and check if our account is there
    RESULT=$(az cognitiveservices account list-deleted --subscription "$subscription" --query "[?name=='$account_name'].name" --output tsv 2>&1)
    if [ "$RESULT" == "$account_name" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# =============================================================================
# Resource Status Check
# =============================================================================

check_all_resources_status() {
    print_header "Checking Resource Status"

    echo "Checking if resources exist..."
    echo ""

    # Check Resource Group
    echo -n "Resource Group [$AZURE_RESOURCE_GROUP]: "
    if [ "$(check_resource_group_exists "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_success "EXISTS"
        RG_EXISTS=true
    else
        print_warning "NOT FOUND"
        RG_EXISTS=false
    fi

    # Check VM (only if RG exists)
    echo -n "Virtual Machine [$VM_NAME]: "
    if [ "$RG_EXISTS" == "true" ]; then
        if [ "$(check_vm_exists "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
            print_success "EXISTS"
            VM_EXISTS=true
        else
            print_warning "NOT FOUND"
            VM_EXISTS=false
        fi
    else
        print_info "SKIPPED (Resource Group doesn't exist)"
        VM_EXISTS=false
    fi

    # Check AKS Cluster
    echo -n "AKS Cluster [$AKS_CLUSTER_NAME]: "
    if [ "$RG_EXISTS" == "true" ]; then
        if [ "$(check_aks_exists "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
            print_success "EXISTS"
            AKS_EXISTS=true
        else
            print_warning "NOT FOUND"
            AKS_EXISTS=false
        fi
    else
        print_info "SKIPPED (Resource Group doesn't exist)"
        AKS_EXISTS=false
    fi

    # Check AI Foundry
    echo -n "AI Foundry [$AIFOUNDRY_NAME]: "
    if [ "$RG_EXISTS" == "true" ]; then
        if [ "$(check_aifoundry_exists "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
            print_success "EXISTS"
            AIFOUNDRY_EXISTS=true
        else
            print_warning "NOT FOUND"
            AIFOUNDRY_EXISTS=false
        fi
    else
        print_info "SKIPPED (Resource Group doesn't exist)"
        AIFOUNDRY_EXISTS=false
    fi

    # Check for soft-deleted AI Foundry
    echo -n "AI Foundry (Soft-Deleted): "
    if [ "$(check_aifoundry_deleted "$AIFOUNDRY_NAME" "$AZURE_LOCATION" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "EXISTS (can be purged)"
        AIFOUNDRY_DELETED=true
    else
        print_info "NOT FOUND"
        AIFOUNDRY_DELETED=false
    fi

    echo ""
}

# =============================================================================
# Delete Functions
# =============================================================================

delete_virtual_machine() {
    print_header "Deleting Virtual Machine: $VM_NAME"

    if [ "$(check_vm_exists "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "false" ]; then
        print_warning "Virtual Machine does not exist. Skipping."
        return 0
    fi

    echo "Deleting VM and associated resources..."
    echo "This will delete: VM, OS disk, NIC, Public IP, NSG, VNet"
    echo ""

    # Delete VM (this also deletes the OS disk by default in newer CLI versions)
    az vm delete \
        --name "$VM_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --yes \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "Virtual Machine deleted."
        send_dt_event "D01-Delete-VM" ',"status":"Deleted"'
    else
        print_error "Failed to delete Virtual Machine."
        send_dt_event "D01-Delete-VM-FAILED" ',"status":"FAILED"'
        return 1
    fi

    # Clean up associated network resources
    echo "Cleaning up network resources..."

    # Delete NIC
    az network nic delete \
        --name "${VM_NAME}VMNic" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output none 2>/dev/null

    # Delete Public IP
    az network public-ip delete \
        --name "${VM_NAME}-ip" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output none 2>/dev/null

    # Delete NSG
    az network nsg delete \
        --name "${VM_NAME}-nsg" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output none 2>/dev/null

    # Delete VNet
    az network vnet delete \
        --name "${VM_NAME}-vnet" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output none 2>/dev/null

    print_success "Network resources cleaned up."
}

delete_aks_cluster() {
    print_header "Deleting AKS Cluster: $AKS_CLUSTER_NAME"

    if [ "$(check_aks_exists "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "false" ]; then
        print_warning "AKS Cluster does not exist. Skipping."
        return 0
    fi

    echo "Deleting AKS Cluster..."
    echo "This may take several minutes..."
    echo ""

    az aks delete \
        --name "$AKS_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --yes \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "AKS Cluster deleted."
        send_dt_event "D02-Delete-AKS-cluster" ',"status":"Deleted"'
    else
        print_error "Failed to delete AKS Cluster."
        send_dt_event "D02-Delete-AKS-cluster-FAILED" ',"status":"FAILED"'
        return 1
    fi

    # Clean up the AKS node resource group if it exists
    AKS_NODE_RG="MC_${AZURE_RESOURCE_GROUP}_${AKS_CLUSTER_NAME}_${AZURE_LOCATION}"
    echo "Checking for AKS node resource group: $AKS_NODE_RG"
    if [ "$(check_resource_group_exists "$AKS_NODE_RG" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        echo "Deleting AKS node resource group..."
        az group delete \
            --name "$AKS_NODE_RG" \
            --subscription "$AZURE_SUBSCRIPTION" \
            --yes \
            --no-wait \
            --output none 2>/dev/null
        print_success "AKS node resource group deletion initiated."
    fi
}

delete_ai_foundry() {
    print_header "Deleting AI Foundry: $AIFOUNDRY_NAME"

    if [ "$(check_aifoundry_exists "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "false" ]; then
        print_warning "AI Foundry does not exist. Skipping."
        return 0
    fi

    echo "Deleting AI Foundry (Cognitive Services) account..."
    echo ""

    # First, delete any deployments
    echo "Checking for model deployments..."
    DEPLOYMENTS=$(az cognitiveservices account deployment list \
        --name "$AIFOUNDRY_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --query "[].name" \
        --output tsv 2>/dev/null)

    if [ -n "$DEPLOYMENTS" ]; then
        echo "Deleting model deployments..."
        for deployment in $DEPLOYMENTS; do
            echo "  Deleting deployment: $deployment"
            az cognitiveservices account deployment delete \
                --name "$AIFOUNDRY_NAME" \
                --resource-group "$AZURE_RESOURCE_GROUP" \
                --subscription "$AZURE_SUBSCRIPTION" \
                --deployment-name "$deployment" \
                --output none 2>/dev/null
        done
        print_success "Model deployments deleted."
    fi

    # Delete the Cognitive Services account (soft delete)
    az cognitiveservices account delete \
        --name "$AIFOUNDRY_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "AI Foundry deleted (soft-deleted)."
        send_dt_event "D03-Delete-AI-Foundry" ',"status":"Soft-Deleted"'
        echo ""
        print_info "Note: The resource is now in soft-deleted state."
        print_info "Use --purge flag or run purge_ai_foundry to permanently delete."
    else
        print_error "Failed to delete AI Foundry."
        send_dt_event "D03-Delete-AI-Foundry-FAILED" ',"status":"FAILED"'
        return 1
    fi
}

purge_ai_foundry() {
    print_header "Purging AI Foundry: $AIFOUNDRY_NAME"

    echo "Checking for soft-deleted AI Foundry resources..."
    echo ""

    # Check if the resource is in deleted state
    if [ "$(check_aifoundry_deleted "$AIFOUNDRY_NAME" "$AZURE_LOCATION" "$AZURE_SUBSCRIPTION")" == "false" ]; then
        print_warning "No soft-deleted AI Foundry resource found with name: $AIFOUNDRY_NAME"
        print_info "The resource may not exist or was already purged."
        return 0
    fi

    print_warning "Found soft-deleted AI Foundry resource: $AIFOUNDRY_NAME"
    echo ""
    echo "Purging will PERMANENTLY delete this resource."
    echo "This action cannot be undone and the resource cannot be recovered."
    echo ""

    read -p "Are you sure you want to PURGE this resource? (yes/no): " CONFIRM_PURGE
    if [ "$CONFIRM_PURGE" != "yes" ]; then
        echo "Purge cancelled."
        return 0
    fi

    echo ""
    echo "Purging AI Foundry resource..."

    # Purge the deleted cognitive services account
    # az cognitiveservices account purge --name <name> --resource-group <rg> --location <location>
    az cognitiveservices account purge \
        --name "$AIFOUNDRY_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output none 2>&1

    if [ $? -eq 0 ]; then
        print_success "AI Foundry resource PURGED permanently."
        send_dt_event "D04-Purge-AI-Foundry" ',"status":"Purged"'
    else
        print_error "Failed to purge AI Foundry resource."
        send_dt_event "D04-Purge-AI-Foundry-FAILED" ',"status":"FAILED"'
        echo ""
        print_info "You may need to wait a few minutes after deletion before purging."
        print_info "Or try manually: az cognitiveservices account purge --name $AIFOUNDRY_NAME --resource-group $AZURE_RESOURCE_GROUP --location $AZURE_LOCATION"
        return 1
    fi
}

delete_resource_group() {
    print_header "Deleting Resource Group: $AZURE_RESOURCE_GROUP"

    if [ "$(check_resource_group_exists "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "false" ]; then
        print_warning "Resource Group does not exist. Skipping."
        return 0
    fi

    echo "Deleting Resource Group and ALL remaining resources within it..."
    echo ""
    print_warning "This will delete ALL resources in the resource group!"
    echo ""

    read -p "Are you sure you want to delete the resource group? (yes/no): " CONFIRM_RG
    if [ "$CONFIRM_RG" != "yes" ]; then
        echo "Resource Group deletion cancelled."
        return 0
    fi

    echo ""
    echo "Deleting Resource Group (this may take several minutes)..."

    az group delete \
        --name "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --yes \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "Resource Group deleted."
        send_dt_event "D05-Delete-Resource-Group" ',"status":"Deleted"'
    else
        print_error "Failed to delete Resource Group."
        send_dt_event "D05-Delete-Resource-Group-FAILED" ',"status":"FAILED"'
        return 1
    fi
}

# =============================================================================
# Input Gathering
# =============================================================================

gather_inputs() {
    print_header "Azure Workshop Delete Script"

    echo ""
    echo "This script will DELETE the following Azure resources:"
    echo "  1. Virtual Machine: $DEFAULT_VM_NAME"
    echo "  2. AKS Cluster:     $DEFAULT_AKS_CLUSTER_NAME"
    echo "  3. AI Foundry:      $DEFAULT_AIFOUNDRY_NAME"
    echo "  4. Resource Group:  $DEFAULT_RESOURCE_GROUP (and all contents)"
    echo ""
    if [ "$PURGE_AIFOUNDRY" == "true" ]; then
        echo -e "  ${RED}5. PURGE AI Foundry (permanent deletion)${NC}"
        echo ""
    fi
    echo "Please provide the required inputs:"
    echo "-------------------------------------------------------------------"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    # Validate subscription
    if [ -z "$AZURE_SUBSCRIPTION" ]; then
        print_error "Azure Subscription ID is required."
        exit 1
    fi

    # Get Resource Group Name (with default)
    read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

    # Get Azure Location (needed for purge)
    read -p "Azure Location (default: $DEFAULT_LOCATION): " AZURE_LOCATION_INPUT
    AZURE_LOCATION=${AZURE_LOCATION_INPUT:-$DEFAULT_LOCATION}

    # Set resource names
    VM_NAME="$DEFAULT_VM_NAME"
    AKS_CLUSTER_NAME="$DEFAULT_AKS_CLUSTER_NAME"
    AIFOUNDRY_NAME="$DEFAULT_AIFOUNDRY_NAME"

    # Derive email from Azure CLI
    EMAIL=$(az account show --query user.name --output tsv 2>/dev/null)
    EMAIL=$(echo $EMAIL | cut -d'#' -f 2)

    # Load Dynatrace credentials from workshop-credentials.json if available
    CREDS_FILE="../gen/workshop-credentials.json"
    if [ -f "$CREDS_FILE" ]; then
        DT_ENVIRONMENT_ID=$(cat "$CREDS_FILE" | jq -r '.DT_ENVIRONMENT_ID // empty')
        if [ -n "$DT_ENVIRONMENT_ID" ]; then
            echo ""
            print_info "Loaded Dynatrace Environment ID from $CREDS_FILE"
            print_info "Deletion events will be sent to Dynatrace."
        fi
    fi

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Delete Configuration:"
    echo "-------------------------------------------------------------------"
    echo "  Subscription:      $AZURE_SUBSCRIPTION"
    echo "  Resource Group:    $AZURE_RESOURCE_GROUP"
    echo "  Location:          $AZURE_LOCATION"
    echo "  VM Name:           $VM_NAME"
    echo "  AKS Cluster:       $AKS_CLUSTER_NAME"
    echo "  AI Foundry:        $AIFOUNDRY_NAME"
    if [ "$PURGE_AIFOUNDRY" == "true" ]; then
        echo -e "  ${RED}Purge AI Foundry:   YES (permanent)${NC}"
    fi
    echo "-------------------------------------------------------------------"
    echo ""

    print_warning "WARNING: This will permanently delete Azure resources!"
    echo ""
    read -p "Proceed with deletion? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Deletion cancelled."
        exit 0
    fi
}

# =============================================================================
# Check Only Mode
# =============================================================================

check_only_mode() {
    print_header "Resource Check Mode"

    echo ""
    echo "-------------------------------------------------------------------"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    # Get Resource Group Name (with default)
    read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

    # Get Azure Location (needed for checking soft-deleted resources)
    read -p "Azure Location (default: $DEFAULT_LOCATION): " AZURE_LOCATION_INPUT
    AZURE_LOCATION=${AZURE_LOCATION_INPUT:-$DEFAULT_LOCATION}

    # Set resource names
    VM_NAME="$DEFAULT_VM_NAME"
    AKS_CLUSTER_NAME="$DEFAULT_AKS_CLUSTER_NAME"
    AIFOUNDRY_NAME="$DEFAULT_AIFOUNDRY_NAME"

    check_all_resources_status
}

# =============================================================================
# Purge Only Mode
# =============================================================================

purge_only_mode() {
    print_header "Purge Soft-Deleted AI Foundry"

    echo ""
    echo "This will permanently purge a soft-deleted AI Foundry resource."
    echo "-------------------------------------------------------------------"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    # Get Resource Group Name (with default)
    read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

    # Get Azure Location
    read -p "Azure Location (default: $DEFAULT_LOCATION): " AZURE_LOCATION_INPUT
    AZURE_LOCATION=${AZURE_LOCATION_INPUT:-$DEFAULT_LOCATION}

    # Get AI Foundry Name
    read -p "AI Foundry Name (default: $DEFAULT_AIFOUNDRY_NAME): " AIFOUNDRY_NAME_INPUT
    AIFOUNDRY_NAME=${AIFOUNDRY_NAME_INPUT:-$DEFAULT_AIFOUNDRY_NAME}

    echo ""

    purge_ai_foundry
}

# =============================================================================
# List Deleted Resources Mode
# =============================================================================

list_deleted_mode() {
    print_header "List Soft-Deleted Cognitive Services Resources"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    echo ""
    echo "Fetching soft-deleted Cognitive Services resources..."
    echo ""

    az cognitiveservices account list-deleted \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output table

    echo ""
    print_info "Use '--purge-only' to permanently delete a soft-deleted resource."
}

# =============================================================================
# Usage Information
# =============================================================================

show_usage() {
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  (no option)       Interactive delete of all workshop resources"
    echo "  --purge           Delete all resources AND purge AI Foundry permanently"
    echo "  --check           Check resource status without deleting"
    echo "  --purge-only      Purge a soft-deleted AI Foundry resource only"
    echo "  --list-deleted    List all soft-deleted Cognitive Services resources"
    echo "  --help            Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                    # Interactive delete (prompts for confirmation)"
    echo "  $0 --purge            # Delete all + purge AI Foundry permanently"
    echo "  $0 --check            # Check what resources exist"
    echo "  $0 --purge-only       # Only purge soft-deleted AI Foundry"
    echo "  $0 --list-deleted     # List soft-deleted Cognitive Services"
    echo ""
    echo "Notes:"
    echo "  - AI Foundry (Cognitive Services) uses soft-delete by default"
    echo "  - Soft-deleted resources can be recovered within 48 hours"
    echo "  - Use --purge to permanently delete and free up the resource name"
    echo "  - Purging cannot be undone - the resource is permanently lost"
    echo ""
}

# =============================================================================
# Print Deletion Summary
# =============================================================================

print_deletion_summary() {
    print_header "Deletion Summary"

    echo ""
    echo "Final Resource Status:"
    echo "-------------------------------------------------------------------"

    # Check final status of each resource
    echo -n "Resource Group [$AZURE_RESOURCE_GROUP]: "
    if [ "$(check_resource_group_exists "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "STILL EXISTS"
    else
        print_success "DELETED"
    fi

    echo -n "Virtual Machine [$VM_NAME]: "
    if [ "$(check_vm_exists "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "STILL EXISTS"
    else
        print_success "DELETED"
    fi

    echo -n "AKS Cluster [$AKS_CLUSTER_NAME]: "
    if [ "$(check_aks_exists "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "STILL EXISTS"
    else
        print_success "DELETED"
    fi

    echo -n "AI Foundry [$AIFOUNDRY_NAME]: "
    if [ "$(check_aifoundry_exists "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "STILL EXISTS"
    else
        print_success "DELETED"
    fi

    # Check soft-deleted status
    echo -n "AI Foundry (Soft-Deleted): "
    if [ "$(check_aifoundry_deleted "$AIFOUNDRY_NAME" "$AZURE_LOCATION" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "EXISTS (run --purge-only to permanently delete)"
    else
        print_success "NOT PRESENT / PURGED"
    fi

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Deletion completed at: $(date)"
    echo "-------------------------------------------------------------------"
}

# =============================================================================
# Main Script Execution
# =============================================================================

main() {
    # Parse command line arguments
    case "$1" in
        --check)
            check_only_mode
            exit 0
            ;;
        --purge)
            PURGE_AIFOUNDRY=true
            ;;
        --purge-only)
            purge_only_mode
            exit 0
            ;;
        --list-deleted)
            list_deleted_mode
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        "")
            # Default interactive mode
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac

    # Gather inputs
    gather_inputs

    # Check current status
    check_all_resources_status

    # Confirm one more time
    echo ""
    print_warning "Starting deletion process..."
    echo ""

    # Send deletion started event
    send_dt_event "D00-Workshop-deletion-started" ',"purge":"'"$PURGE_AIFOUNDRY"'"'

    # Delete in reverse order of creation (dependencies first)
    # 1. Delete AI Foundry first (so we can purge it later if needed)
    delete_ai_foundry

    # 2. Delete AKS Cluster
    delete_aks_cluster

    # 3. Delete VM
    delete_virtual_machine

    # 4. Delete Resource Group (this will clean up any remaining resources)
    delete_resource_group

    # 5. Purge AI Foundry if requested
    if [ "$PURGE_AIFOUNDRY" == "true" ]; then
        echo ""
        echo "Waiting 10 seconds for soft-delete to complete..."
        sleep 10
        purge_ai_foundry
    fi

    # Print summary
    print_deletion_summary

    # Send completion event
    if [ "$PURGE_AIFOUNDRY" == "true" ]; then
        send_dt_event "D99-Workshop-deletion-complete" ',"status":"All resources deleted and purged"'
    else
        send_dt_event "D99-Workshop-deletion-complete" ',"status":"All resources deleted (AI Foundry soft-deleted)"'
    fi

    echo ""
    if [ "$PURGE_AIFOUNDRY" == "false" ]; then
        print_info "Note: AI Foundry is soft-deleted and can be recovered within 48 hours."
        print_info "To permanently delete, run: $0 --purge-only"
    fi
    echo ""
}

# Run main function
main "$@"
