#!/bin/bash

# =============================================================================
# Enable SSH Access Script
# =============================================================================
# This script enables SSH access (port 22) on the workshop VM.
# By default, SSH is disabled for security. Use this script when you need
# to SSH into the VM for troubleshooting or maintenance.
#
# Usage:
#   ./enable-ssh.sh              # Enable SSH from all IPs (0.0.0.0/0)
#   ./enable-ssh.sh <IP_CIDR>    # Enable SSH from specific IP range
#
# Examples:
#   ./enable-ssh.sh                    # Allow from anywhere
#   ./enable-ssh.sh 203.0.113.50/32    # Allow from single IP
#   ./enable-ssh.sh 10.0.0.0/8         # Allow from IP range
# =============================================================================

# Colors
YLW='\033[1;33m'
GRN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Default values
DEFAULT_RESOURCE_GROUP="dynatrace-azure-workshop"
DEFAULT_VM_NAME="dt-orders-monolith"

# Source IP (default: all IPs)
SOURCE_IP="${1:-0.0.0.0/0}"

echo ""
echo "==========================================================================="
echo -e "${YLW}Enable SSH Access on Workshop VM${NC}"
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
echo "  Source IP:       $SOURCE_IP"
echo "-------------------------------------------------------------------"
echo ""

if [ "$SOURCE_IP" == "0.0.0.0/0" ]; then
    echo -e "${YLW}WARNING: This will allow SSH access from ANY IP address.${NC}"
    echo "For better security, consider specifying your IP address."
    echo ""
fi

read -p "Proceed with enabling SSH? (y/n): " CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo "Operation cancelled."
    exit 0
fi

echo ""
echo "Enabling SSH access..."

# Create NSG rule for SSH
az network nsg rule create \
    --resource-group "$AZURE_RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "allow-ssh" \
    --priority 1000 \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --destination-port-ranges 22 \
    --source-address-prefixes "$SOURCE_IP" \
    --subscription "$AZURE_SUBSCRIPTION" \
    --output none 2>/dev/null

if [ $? -eq 0 ]; then
    echo -e "${GRN}SSH access enabled successfully!${NC}"
    echo ""

    # Get VM public IP
    VM_IP=$(az vm show \
        --name "$VM_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --show-details \
        --query publicIps \
        --output tsv 2>/dev/null)

    if [ -n "$VM_IP" ]; then
        echo "Connect to the VM with:"
        echo "  ssh workshop@$VM_IP"
        echo ""
    fi

    echo "To disable SSH access later:"
    echo "  ./disable-ssh.sh"
    echo ""
else
    echo -e "${RED}Failed to enable SSH access.${NC}"
    echo "Please check that:"
    echo "  - Resource group '$AZURE_RESOURCE_GROUP' exists"
    echo "  - NSG '$NSG_NAME' exists"
    echo "  - You have permission to modify NSG rules"
    exit 1
fi
