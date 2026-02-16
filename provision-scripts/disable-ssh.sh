#!/bin/bash

# =============================================================================
# Disable SSH Access Script
# =============================================================================
# This script disables SSH access (port 22) on the workshop VM.
# Use this to restore the default security posture after SSH maintenance.
# =============================================================================

# Colors
YLW='\033[1;33m'
GRN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Default values
DEFAULT_RESOURCE_GROUP="dynatrace-azure-workshop"
DEFAULT_VM_NAME="dt-orders-monolith"

echo ""
echo "==========================================================================="
echo -e "${YLW}Disable SSH Access on Workshop VM${NC}"
echo "==========================================================================="
echo ""

# Get Azure Subscription ID
CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
if [ -z "$CURRENT_SUBSCRIPTION" ]; then
    echo -e "${RED}ERROR: Not logged into Azure CLI. Run 'az login' first.${NC}"
    exit 1
fi

read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

read -p "Virtual Machine Name (default: $DEFAULT_VM_NAME): " VM_NAME_INPUT
VM_NAME=${VM_NAME_INPUT:-$DEFAULT_VM_NAME}

NSG_NAME="${VM_NAME}-nsg"

echo ""
echo "-------------------------------------------------------------------"
echo "Configuration:"
echo "-------------------------------------------------------------------"
echo "  Subscription:    $AZURE_SUBSCRIPTION"
echo "  Resource Group:  $AZURE_RESOURCE_GROUP"
echo "  VM Name:         $VM_NAME"
echo "  NSG Name:        $NSG_NAME"
echo "-------------------------------------------------------------------"
echo ""

read -p "Proceed with disabling SSH? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Operation cancelled."
    exit 0
fi

echo ""
echo "Disabling SSH access..."

# Delete the SSH NSG rule
az network nsg rule delete \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "allow-ssh" \
    --subscription "$AZURE_SUBSCRIPTION" \
    --output none 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GRN}SSH access disabled successfully!${NC}"
    echo ""
    echo "To re-enable SSH access:"
    echo "  ./enable-ssh.sh"
    echo ""
else
    # Try to delete the default rule name as well
    az network nsg rule delete \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --nsg-name "$NSG_NAME" \
        --name "default-allow-ssh" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        echo -e "${GRN}SSH access disabled successfully!${NC}"
        echo ""
    else
        echo -e "${YLW}No SSH rule found to delete. SSH may already be disabled.${NC}"
        echo ""
    fi
fi
