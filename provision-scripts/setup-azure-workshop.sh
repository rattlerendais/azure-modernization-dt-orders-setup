#!/bin/bash

# =============================================================================
# Azure Workshop Setup Script
# Provisions and configures: Resource Group, VM, AKS Cluster, AI Foundry
#
# Usage:
#   ./setup-azure-workshop.sh                       # Provision all resources
#   ./setup-azure-workshop.sh --check               # Check resource status
#   ./setup-azure-workshop.sh --configure-workshop  # Configure VM + save creds
#   ./setup-azure-workshop.sh --help                # Show all options
# =============================================================================

# Colors for output
YLW='\033[1;33m'
GRN='\033[0;32m'
RED='\033[0;31m'
BLU='\033[0;34m'
NC='\033[0m'

# Default values
DEFAULT_LOCATION="eastus"
DEFAULT_VM_SIZE="Standard_DS11-1_v2"
DEFAULT_AKS_NODE_COUNT=4
DEFAULT_AKS_NODE_SIZE="Standard_DS2_v2"

# Hardcoded resource names (matching existing workshop scripts)
DEFAULT_RESOURCE_GROUP="dynatrace-azure-workshop"
DEFAULT_VM_NAME="dt-orders-monolith"
DEFAULT_AKS_CLUSTER_NAME="dynatrace-azure-workshop-cluster"
DEFAULT_AIFOUNDRY_NAME="dynatrace-azure-workshop-aifoundry"

# VM credentials
VM_ADMIN_USERNAME="workshop"
# Password is base64 encoded to avoid plaintext visibility
VM_ADMIN_PASSWORD=$(echo "V29ya3Nob3AxMjMj" | base64 -d 2>/dev/null || echo "V29ya3Nob3AxMjMj" | base64 --decode 2>/dev/null)

# Dynatrace Event Tracking (optional - set these for event tracking)
DT_EVENT_ENDPOINT="https://dt-event-send-dteve5duhvdddbea.eastus2-01.azurewebsites.net/api/send-event"
EMAIL=""
DT_ENVIRONMENT_ID=""

# =============================================================================
# Helper Functions
# =============================================================================

# Send provisioning event to Dynatrace (if EMAIL and DT_ENVIRONMENT_ID are set)
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
# Prerequisites Check
# =============================================================================

check_prerequisites() {
    CREDS_FILE="../gen/workshop-credentials.json"

    # Check if credentials file exists
    if [ ! -f "$CREDS_FILE" ]; then
        print_header "Prerequisites Check Failed"
        echo ""
        print_error "Workshop credentials file not found: $CREDS_FILE"
        echo ""
        echo "Before running this script, you must first set up your Dynatrace credentials."
        echo ""
        echo "Please run the following command first:"
        echo ""
        echo -e "  ${GRN}./input-credentials.sh${NC}"
        echo ""
        echo "This will create the credentials file with your Dynatrace environment details."
        echo ""
        exit 1
    fi

    # Validate that the credentials file has required fields
    DT_ENVIRONMENT_ID_CHECK=$(cat "$CREDS_FILE" | jq -r '.DT_ENVIRONMENT_ID // empty' 2>/dev/null)
    if [ -z "$DT_ENVIRONMENT_ID_CHECK" ]; then
        print_header "Prerequisites Check Failed"
        echo ""
        print_error "Credentials file exists but is missing DT_ENVIRONMENT_ID"
        echo ""
        echo "Please re-run the credentials setup:"
        echo ""
        echo -e "  ${GRN}./input-credentials.sh${NC}"
        echo ""
        exit 1
    fi

    print_success "Prerequisites check passed - credentials file found"
}

# =============================================================================
# Input Gathering
# =============================================================================

gather_inputs() {
    print_header "Azure Resource Provisioning Script"

    echo ""
    echo "This script will create the following Azure resources:"
    echo "  1. Resource Group:  $DEFAULT_RESOURCE_GROUP"
    echo "  2. Virtual Machine: $DEFAULT_VM_NAME"
    echo "  3. AKS Cluster:     $DEFAULT_AKS_CLUSTER_NAME"
    echo "  4. AI Foundry:      $DEFAULT_AIFOUNDRY_NAME"
    echo ""
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

    # Get Azure Location
    read -p "Azure Location (default: $DEFAULT_LOCATION): " AZURE_LOCATION_INPUT
    AZURE_LOCATION=${AZURE_LOCATION_INPUT:-$DEFAULT_LOCATION}

    # Set hardcoded resource names
    VM_NAME="$DEFAULT_VM_NAME"
    AKS_CLUSTER_NAME="$DEFAULT_AKS_CLUSTER_NAME"
    AIFOUNDRY_NAME="$DEFAULT_AIFOUNDRY_NAME"

    # Derive email from Azure CLI (same approach as input-credentials.sh)
    EMAIL=$(az account show --query user.name --output tsv 2>/dev/null)
    EMAIL=$(echo $EMAIL | cut -d'#' -f 2)

    # Load Dynatrace credentials from workshop-credentials.json if available
    CREDS_FILE="../gen/workshop-credentials.json"
    if [ -f "$CREDS_FILE" ]; then
        DT_ENVIRONMENT_ID=$(cat "$CREDS_FILE" | jq -r '.DT_ENVIRONMENT_ID // empty')
        if [ -n "$DT_ENVIRONMENT_ID" ]; then
            echo ""
            print_info "Loaded Dynatrace Environment ID from $CREDS_FILE"
        fi
    fi

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Configuration Summary:"
    echo "-------------------------------------------------------------------"
    echo "  Subscription:      $AZURE_SUBSCRIPTION"
    echo "  Resource Group:    $AZURE_RESOURCE_GROUP"
    echo "  Location:          $AZURE_LOCATION"
    echo "  VM Name:           $VM_NAME"
    echo "  AKS Cluster:       $AKS_CLUSTER_NAME"
    echo "  AI Foundry:        $AIFOUNDRY_NAME"
    echo "-------------------------------------------------------------------"
    echo ""

    read -p "Proceed with provisioning? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Provisioning cancelled."
        exit 0
    fi
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

# Tag update functions - ensure Owner tag exists on resources
WORKSHOP_TAG="Owner=dynatrace-azure-workshop"

ensure_resource_group_tags() {
    local rg_name=$1
    local subscription=$2

    # Check if Owner tag exists
    CURRENT_TAG=$(az group show --name "$rg_name" --subscription "$subscription" --query "tags.Owner" --output tsv 2>/dev/null)
    if [ "$CURRENT_TAG" != "dynatrace-azure-workshop" ]; then
        echo "  Adding tag to Resource Group..."
        az group update --name "$rg_name" --subscription "$subscription" --tags "$WORKSHOP_TAG" --output none 2>/dev/null
    fi
}

ensure_vm_tags() {
    local vm_name=$1
    local rg_name=$2
    local subscription=$3

    # Check if Owner tag exists
    CURRENT_TAG=$(az vm show --name "$vm_name" --resource-group "$rg_name" --subscription "$subscription" --query "tags.Owner" --output tsv 2>/dev/null)
    if [ "$CURRENT_TAG" != "dynatrace-azure-workshop" ]; then
        echo "  Adding tag to Virtual Machine..."
        az vm update --name "$vm_name" --resource-group "$rg_name" --subscription "$subscription" --set tags.Owner="dynatrace-azure-workshop" --output none 2>/dev/null
    fi
}

ensure_aks_tags() {
    local aks_name=$1
    local rg_name=$2
    local subscription=$3

    # Check if Owner tag exists
    CURRENT_TAG=$(az aks show --name "$aks_name" --resource-group "$rg_name" --subscription "$subscription" --query "tags.Owner" --output tsv 2>/dev/null)
    if [ "$CURRENT_TAG" != "dynatrace-azure-workshop" ]; then
        echo "  Adding tag to AKS Cluster..."
        az aks update --name "$aks_name" --resource-group "$rg_name" --subscription "$subscription" --tags "$WORKSHOP_TAG" --output none 2>/dev/null
    fi
}

ensure_aifoundry_tags() {
    local account_name=$1
    local rg_name=$2
    local subscription=$3

    # Check if Owner tag exists
    CURRENT_TAG=$(az cognitiveservices account show --name "$account_name" --resource-group "$rg_name" --subscription "$subscription" --query "tags.Owner" --output tsv 2>/dev/null)
    if [ "$CURRENT_TAG" != "dynatrace-azure-workshop" ]; then
        echo "  Adding tag to AI Foundry..."
        az cognitiveservices account update --name "$account_name" --resource-group "$rg_name" --subscription "$subscription" --tags "$WORKSHOP_TAG" --output none 2>/dev/null
    fi
}

# =============================================================================
# Resource Status Check (Check Only Mode)
# =============================================================================

check_all_resources_status() {
    print_header "Checking Resource Status"

    echo "Checking if resources already exist..."
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

    echo ""

    # Send DT event with resource status summary
    send_dt_event "00-Check-resources-status" ',"resourceGroup.exists":"'"$RG_EXISTS"'","vm.exists":"'"$VM_EXISTS"'","aks.exists":"'"$AKS_EXISTS"'","aifoundry.exists":"'"$AIFOUNDRY_EXISTS"'"'
}

# =============================================================================
# Resource Provider Registration
# =============================================================================

register_resource_providers() {
    print_header "Step 01: Registering Required Resource Providers"

    local providers=("Microsoft.Compute" "Microsoft.ContainerService" "Microsoft.CognitiveServices" "Microsoft.OperationsManagement" "microsoft.insights")
    local step_num=1

    for provider in "${providers[@]}"; do
        echo -n "Checking $provider: "
        STATUS=$(az provider show --namespace "$provider" --query "registrationState" --output tsv 2>/dev/null)

        if [ "$STATUS" == "Registered" ]; then
            print_success "Already registered"
        else
            echo -n "Registering... "
            az provider register --namespace "$provider" --only-show-errors
            print_success "Registration initiated"
        fi
        step_num=$((step_num + 1))
    done

    # Send single event for all resource provider registrations
    send_dt_event "01-Register-resource-providers"

    echo ""
    print_info "Note: Resource provider registration may take a few minutes to complete."
}

# =============================================================================
# Resource Creation Functions
# =============================================================================

create_resource_group() {
    print_header "Step 02: Creating Resource Group: $AZURE_RESOURCE_GROUP"

    if [ "$(check_resource_group_exists "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "Resource Group already exists. Skipping creation."
        ensure_resource_group_tags "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION"
        send_dt_event "02-Create-resource-group" ',"status":"Already exists"'
        return 0
    fi

    echo "Creating resource group in $AZURE_LOCATION..."
    az group create \
        --name "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --tags "Owner=dynatrace-azure-workshop" \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "Resource Group created successfully."
        send_dt_event "02-Create-resource-group" ',"status":"Created"'
    else
        print_error "Failed to create Resource Group."
        send_dt_event "90-Create-resource-group-FAILED" ',"status":"FAILED"'
        return 1
    fi
}

create_virtual_machine() {
    print_header "Step 03: Creating Virtual Machine: $VM_NAME"

    if [ "$(check_vm_exists "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "Virtual Machine already exists. Skipping creation."
        ensure_vm_tags "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION"
        send_dt_event "03-Provision-VM" ',"vmState":"Already exists"'
        return 0
    fi

    echo "Creating VM with the following configuration:"
    echo "  - Size: $DEFAULT_VM_SIZE"
    echo "  - Image: Ubuntu 22.04 LTS"
    echo "  - Admin User: $VM_ADMIN_USERNAME"
    echo ""

    # Clean up any orphaned network resources from previous failed deployments
    echo "Checking for orphaned network resources..."
    az network public-ip delete --name "${VM_NAME}-ip" -g "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --output none 2>/dev/null
    az network nsg delete --name "${VM_NAME}-nsg" -g "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --output none 2>/dev/null
    az network vnet delete --name "${VM_NAME}-vnet" -g "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --output none 2>/dev/null
    az disk list -g "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --query "[?starts_with(name, '${VM_NAME}')].name" -o tsv 2>/dev/null | while read disk; do
        az disk delete --name "$disk" -g "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --yes --output none 2>/dev/null
    done
    echo ""

    # Capture both stdout and stderr for better error reporting
    # Explicitly name network resources to ensure consistent naming
    VM_OUTPUT=$(az vm create \
        --name "$VM_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --location "$AZURE_LOCATION" \
        --image "Ubuntu2204" \
        --size "$DEFAULT_VM_SIZE" \
        --admin-username "$VM_ADMIN_USERNAME" \
        --admin-password "$VM_ADMIN_PASSWORD" \
        --authentication-type password \
        --public-ip-sku Standard \
        --vnet-name "${VM_NAME}-vnet" \
        --subnet "${VM_NAME}-subnet" \
        --nsg "${VM_NAME}-nsg" \
        --public-ip-address "${VM_NAME}-ip" \
        --tags "Owner=dynatrace-azure-workshop" \
        --output json 2>&1)

    # Filter out WARNING/ERROR lines before parsing JSON with jq
    VM_STATE=$(echo "$VM_OUTPUT" | grep -v "^WARNING:" | grep -v "^ERROR:" | jq -r '.powerState' 2>/dev/null)

    if [ "$VM_STATE" == "VM running" ]; then
        print_success "Virtual Machine created and running."

        # Get VM public IP
        VM_IP=$(az vm show \
            --name "$VM_NAME" \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --subscription "$AZURE_SUBSCRIPTION" \
            --show-details \
            --query publicIps \
            --output tsv)
        print_info "VM Public IP: $VM_IP"

        # Open port 80 for web traffic
        echo "Opening port 80..."
        az vm open-port \
            --port 80 \
            --priority 1010 \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --name "$VM_NAME" \
            --subscription "$AZURE_SUBSCRIPTION" \
            --output none
        print_success "Port 80 opened."

        # Remove default SSH access for security
        echo "Removing default SSH access..."
        az network nsg rule delete \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --nsg-name "${VM_NAME}-nsg" \
            --name "default-allow-ssh" \
            --subscription "$AZURE_SUBSCRIPTION" \
            --output none 2>/dev/null
        if [ $? -eq 0 ]; then
            print_success "SSH access removed (use enable-ssh.sh to re-enable)."
        else
            print_warning "Could not remove SSH rule (may not exist or different name)."
        fi

        # Send event
        send_dt_event "03-Provision-VM" ',"vmState":"VM running"'
    else
        print_error "Virtual Machine creation failed. State: $VM_STATE"
        echo "Error details:"
        echo "$VM_OUTPUT"
        send_dt_event "91-Provision-VM-FAILED" ',"vmState":"FAILED"'
        return 1
    fi
}

create_aks_cluster() {
    print_header "Step 04: Creating AKS Cluster: $AKS_CLUSTER_NAME"

    if [ "$(check_aks_exists "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "AKS Cluster already exists. Skipping creation."
        ensure_aks_tags "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION"
        send_dt_event "04-Create-AKS-cluster" ',"status":"Already exists"'
        return 0
    fi

    echo "Creating AKS Cluster with the following configuration:"
    echo "  - Node Count: $DEFAULT_AKS_NODE_COUNT"
    echo "  - Node Size: $DEFAULT_AKS_NODE_SIZE"
    echo "  - OS: Azure Linux"
    echo "  - Availability Zones: 1, 2, 3"
    echo ""
    echo "This may take several minutes..."

    az aks create \
        --name "$AKS_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --node-count $DEFAULT_AKS_NODE_COUNT \
        --node-vm-size "$DEFAULT_AKS_NODE_SIZE" \
        --os-sku AzureLinux \
        --zones 1 2 3 \
        --enable-addons monitoring \
        --generate-ssh-keys \
        --tags "Owner=dynatrace-azure-workshop" \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "AKS Cluster created successfully."

        # Get AKS credentials
        echo ""
        print_info "To connect to the cluster, run:"
        echo "  az aks get-credentials --resource-group $AZURE_RESOURCE_GROUP --name $AKS_CLUSTER_NAME"

        # Send event
        send_dt_event "04-Create-AKS-cluster" ',"status":"AKS running"'
    else
        print_error "AKS Cluster creation failed."
        send_dt_event "92-Create-AKS-cluster-FAILED" ',"status":"FAILED"'
        return 1
    fi
}

create_ai_foundry() {
    print_header "Step 05: Creating AI Foundry: $AIFOUNDRY_NAME"

    if [ "$(check_aifoundry_exists "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_warning "AI Foundry account already exists. Skipping creation."
        ensure_aifoundry_tags "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION"
        send_dt_event "05-Provision-AI-Foundry" ',"status":"Already exists"'
        return 0
    fi

    echo "Creating AI Foundry (Azure OpenAI) account..."

    AIFOUNDRY_OUTPUT=$(az cognitiveservices account create \
        --name "$AIFOUNDRY_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --kind "AIServices" \
        --sku "S0" \
        --location "$AZURE_LOCATION" \
        --yes \
        --tags "Owner=dynatrace-azure-workshop" \
        --output json 2>&1)
    AIFOUNDRY_EXIT_CODE=$?

    # Check if it already exists (treat as success)
    if echo "$AIFOUNDRY_OUTPUT" | grep -q "already exists"; then
        print_warning "AI Foundry account already exists. Continuing..."
        AIFOUNDRY_EXIT_CODE=0
    fi

    if [ $AIFOUNDRY_EXIT_CODE -eq 0 ]; then
        print_success "AI Foundry account created/verified successfully."

        # Wait for resource to be ready
        echo "Waiting for AI Foundry to be ready..."
        sleep 10

        # Get the endpoint
        ENDPOINT=$(az cognitiveservices account show \
            --name "$AIFOUNDRY_NAME" \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --subscription "$AZURE_SUBSCRIPTION" \
            --query "properties.endpoint" \
            --output tsv)

        print_info "AI Foundry Endpoint: $ENDPOINT"

        # Deploy a model (gpt-4o)
        echo ""
        echo "Deploying gpt-4o model..."
        az cognitiveservices account deployment create \
            --name "$AIFOUNDRY_NAME" \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --subscription "$AZURE_SUBSCRIPTION" \
            --deployment-name "gpt-4o" \
            --model-name "gpt-4o" \
            --model-version "2024-05-13" \
            --model-format "OpenAI" \
            --sku-name "Standard" \
            --sku-capacity 1 \
            --output none 2>/dev/null

        if [ $? -eq 0 ]; then
            print_success "Model gpt-4o deployed successfully."
            # Send event for successful deployment
            send_dt_event "05-Provision-AI-Foundry" ',"status":"Resource and Model Deployed"'
        else
            print_warning "Model deployment may require additional quota or permissions."
            # Send event for partial success
            send_dt_event "05-Provision-AI-Foundry" ',"status":"Resource Created, Model Deployment Failed"'
        fi
    else
        print_error "AI Foundry account creation failed."
        echo "Error details:"
        echo "$AIFOUNDRY_OUTPUT"
        send_dt_event "93-Provision-AI-Foundry-FAILED" ',"status":"Resource Deployment FAILED"'
        return 1
    fi
}

# =============================================================================
# VM Configuration - Clone Workshop Repo
# =============================================================================

configure_vm_workshop() {
    local vm_name=$1
    local rg_name=$2
    local subscription=$3

    print_header "Configuring VM: $vm_name with Workshop Repository"

    # Check if VM exists first
    if [ "$(check_vm_exists "$vm_name" "$rg_name" "$subscription")" == "false" ]; then
        print_error "VM '$vm_name' not found in resource group '$rg_name'."
        send_dt_event "94-Configure-VM-FAILED" ',"status":"VM not found"'
        return 1
    fi

    echo "Running configuration script on VM..."
    echo "This will:"
    echo "  - Update packages and install git, docker"
    echo "  - Create /home/workshop directory"
    echo "  - Clone the azure-modernization-dt-orders-setup repository"
    echo "  - Start the monolith application"
    echo ""

    RESULT=$(az vm run-command invoke \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --subscription "$subscription" \
        --command-id RunShellScript \
        --scripts "
            # Update packages and install prerequisites
            sudo apt-get update -y
            sudo apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common git jq

            # Install Docker from official Docker repository
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
            sudo add-apt-repository -y 'deb [arch=amd64] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable'
            sudo apt-get update -y
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io
            sudo apt-get install -y docker-compose

            # Start and enable docker service
            sudo systemctl start docker
            sudo systemctl enable docker

            # Add workshop user to docker group
            sudo usermod -aG docker workshop 2>/dev/null || sudo usermod -aG docker azureuser 2>/dev/null

            # Create workshop directory
            sudo mkdir -p /home/workshop

            # Clone the repo
            cd /home/workshop
            if [ -d '/home/workshop/azure-modernization-dt-orders-setup' ]; then
                echo 'Repository already exists, pulling latest...'
                cd /home/workshop/azure-modernization-dt-orders-setup
                git pull
            else
                git clone https://github.com/dt-alliances-workshops/azure-modernization-dt-orders-setup.git /home/workshop/azure-modernization-dt-orders-setup
            fi

            # Set permissions
            sudo chown -R workshop:workshop /home/workshop 2>/dev/null || sudo chown -R azureuser:azureuser /home/workshop

            # Add user to sudo group (workshop user if exists, otherwise skip)
            sudo usermod -a -G sudo workshop 2>/dev/null || echo 'workshop user not found, skipping sudo group addition'

            # Start the monolith application
            echo 'Starting monolith application...'
            cd /home/workshop/azure-modernization-dt-orders-setup/app-scripts
            chmod +x start-monolith.sh
            ./start-monolith.sh

            echo 'VM configuration completed successfully!'
        " \
        --query "value[0].message" \
        --output tsv 2>&1)

    if echo "$RESULT" | grep -q "completed successfully"; then
        print_success "VM configured successfully with workshop repository."
        echo ""
        echo "Repository cloned to: /home/workshop/azure-modernization-dt-orders-setup"
        send_dt_event "07-Configure-VM" ',"status":"Success"'
    else
        print_warning "VM configuration completed. Output:"
        echo "$RESULT"
        send_dt_event "07-Configure-VM" ',"status":"Completed with warnings"'
    fi

    # Open port 80 for web traffic
    echo ""
    echo "Opening port 80 for web traffic..."
    az vm open-port \
        --port 80 \
        --priority 1010 \
        --resource-group "$rg_name" \
        --name "$vm_name" \
        --subscription "$subscription" \
        --output none 2>/dev/null

    if [ $? -eq 0 ]; then
        print_success "Port 80 opened successfully."
    else
        print_warning "Port 80 may already be open or could not be configured."
    fi
}

configure_vm_mode() {
    print_header "VM Configuration Mode"

    echo ""
    echo "This will configure an existing VM with the workshop repository."
    echo "-------------------------------------------------------------------"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    # Get Resource Group Name (with default)
    read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

    # Get VM Name (with default)
    read -p "Virtual Machine Name (default: $DEFAULT_VM_NAME): " VM_NAME_INPUT
    VM_NAME=${VM_NAME_INPUT:-$DEFAULT_VM_NAME}

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Configuration Summary:"
    echo "-------------------------------------------------------------------"
    echo "  Subscription:      $AZURE_SUBSCRIPTION"
    echo "  Resource Group:    $AZURE_RESOURCE_GROUP"
    echo "  VM Name:           $VM_NAME"
    echo "-------------------------------------------------------------------"
    echo ""

    read -p "Proceed with VM configuration? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Configuration cancelled."
        exit 0
    fi

    configure_vm_workshop "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION"
}

# =============================================================================
# Save AI Foundry Credentials to workshop-credentials.json
# =============================================================================

save_aifoundry_credentials() {
    local aifoundry_name=$1
    local rg_name=$2
    local subscription=$3
    local creds_file=$4

    print_header "Saving AI Foundry Credentials"

    # Check if AI Foundry exists
    if [ "$(check_aifoundry_exists "$aifoundry_name" "$rg_name" "$subscription")" == "false" ]; then
        print_error "AI Foundry '$aifoundry_name' not found in resource group '$rg_name'."
        send_dt_event "95-Save-AIFoundry-credentials-FAILED" ',"status":"AI Foundry not found"'
        return 1
    fi

    # Get the AI Foundry endpoint
    AZURE_AIFOUNDRY_ENDPOINT=$(az cognitiveservices account show \
        --name "$aifoundry_name" \
        --resource-group "$rg_name" \
        --subscription "$subscription" \
        --query "properties.endpoint" \
        --output tsv 2>/dev/null)

    # Get the AI Foundry API key
    AZURE_AIFOUNDRY_MODEL_KEY=$(az cognitiveservices account keys list \
        --name "$aifoundry_name" \
        --resource-group "$rg_name" \
        --subscription "$subscription" \
        --query "key1" \
        --output tsv 2>/dev/null)

    if [ -z "$AZURE_AIFOUNDRY_ENDPOINT" ]; then
        print_error "Could not retrieve AI Foundry endpoint"
        send_dt_event "95-Save-AIFoundry-credentials-FAILED" ',"status":"Endpoint retrieval failed"'
        return 1
    fi

    if [ -z "$AZURE_AIFOUNDRY_MODEL_KEY" ]; then
        print_error "Could not retrieve AI Foundry API key"
        send_dt_event "95-Save-AIFoundry-credentials-FAILED" ',"status":"API key retrieval failed"'
        return 1
    fi

    print_success "Retrieved AI Foundry credentials"

    # Check if credentials file exists
    if [ ! -f "$creds_file" ]; then
        print_warning "Credentials file not found: $creds_file"
        echo "Creating new credentials file..."
        # Create a minimal JSON file
        echo '{}' > "$creds_file"
    fi

    # Update the credentials file using jq
    TEMP_FILE=$(mktemp)
    jq --arg endpoint "$AZURE_AIFOUNDRY_ENDPOINT" \
       --arg key "$AZURE_AIFOUNDRY_MODEL_KEY" \
       --arg name "$aifoundry_name" \
       '.AZURE_AIFOUNDRY_ENDPOINT = $endpoint | .AZURE_AIFOUNDRY_MODEL_KEY = $key | .AZURE_AIFOUNDRY_NAME = $name' \
       "$creds_file" > "$TEMP_FILE" && mv "$TEMP_FILE" "$creds_file"

    if [ $? -eq 0 ]; then
        print_success "Credentials file updated successfully: $creds_file"
        send_dt_event "08-Save-AIFoundry-credentials" ',"status":"Success"'
    else
        print_error "Failed to update credentials file"
        send_dt_event "95-Save-AIFoundry-credentials-FAILED" ',"status":"Credentials file update failed"'
        return 1
    fi

    # Update the Travel Advisor manifest with AI Foundry and OTEL credentials
    update_traveladvisor_manifest "$AZURE_AIFOUNDRY_ENDPOINT" "$AZURE_AIFOUNDRY_MODEL_KEY" "$creds_file"
}

# =============================================================================
# Update Travel Advisor Manifest with AI Foundry and OTEL credentials
# =============================================================================

update_traveladvisor_manifest() {
    local endpoint=$1
    local api_key=$2
    local creds_file=$3

    TRAVELADVISOR_MANIFEST="../app-scripts/manifests/traveladvisor-combined.yaml"

    if [ ! -f "$TRAVELADVISOR_MANIFEST" ]; then
        print_warning "Travel Advisor manifest not found at $TRAVELADVISOR_MANIFEST"
        send_dt_event "96-Update-TravelAdvisor-manifest-FAILED" ',"status":"Manifest not found"'
        return 1
    fi

    print_header "Updating Travel Advisor Manifest"

    # Read DT credentials from the credentials file for OTEL configuration
    local dt_environment_id=""
    local dt_api_token=""
    if [ -f "$creds_file" ]; then
        dt_environment_id=$(cat "$creds_file" | jq -r '.DT_ENVIRONMENT_ID // empty')
        dt_api_token=$(cat "$creds_file" | jq -r '.DT_API_TOKEN // empty')
    fi

    # Update AZURE_OPENAI_ENDPOINT
    sed -i 's~AZURE_OPENAI_ENDPOINT:.*~AZURE_OPENAI_ENDPOINT: "'"$endpoint"'"~' "$TRAVELADVISOR_MANIFEST"

    # Update AZURE_OPENAI_KEY
    sed -i 's~AZURE_OPENAI_KEY:.*~AZURE_OPENAI_KEY: "'"$api_key"'"~' "$TRAVELADVISOR_MANIFEST"

    # Update AZURE_OPENAI_API_KEY
    sed -i 's~AZURE_OPENAI_API_KEY:.*~AZURE_OPENAI_API_KEY: "'"$api_key"'"~' "$TRAVELADVISOR_MANIFEST"

    print_success "Updated Azure OpenAI credentials"

    # Update OTEL credentials if DT credentials are available
    if [ -n "$dt_environment_id" ] && [ -n "$dt_api_token" ]; then

        local otel_endpoint="https://${dt_environment_id}.live.dynatrace.com/api/v2/otlp"

        # Update OTEL_ENDPOINT
        sed -i 's~OTEL_ENDPOINT:.*~OTEL_ENDPOINT: "'"$otel_endpoint"'"~' "$TRAVELADVISOR_MANIFEST"

        # Update OTEL_API_TOKEN
        sed -i 's~OTEL_API_TOKEN:.*~OTEL_API_TOKEN: "'"$dt_api_token"'"~' "$TRAVELADVISOR_MANIFEST"

        print_success "Updated OTEL credentials"
    else
        print_warning "DT credentials not found in $creds_file - OTEL settings not updated"
        echo "  To configure OTEL, ensure DT_ENVIRONMENT_ID and DT_API_TOKEN are in your credentials file"
    fi

    echo ""
    print_success "Travel Advisor manifest updated: $TRAVELADVISOR_MANIFEST"
    send_dt_event "09-Update-TravelAdvisor-manifest" ',"status":"Success"'
}

save_aifoundry_creds_mode() {
    print_header "Save AI Foundry Credentials Mode"

    echo ""
    echo "This will retrieve AI Foundry endpoint and API key and save to workshop-credentials.json"
    echo "-------------------------------------------------------------------"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    # Get Resource Group Name (with default)
    read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

    # Get AI Foundry Name (with default)
    read -p "AI Foundry Name (default: $DEFAULT_AIFOUNDRY_NAME): " AIFOUNDRY_NAME_INPUT
    AIFOUNDRY_NAME=${AIFOUNDRY_NAME_INPUT:-$DEFAULT_AIFOUNDRY_NAME}

    # Get credentials file path
    DEFAULT_CREDS_FILE="../gen/workshop-credentials.json"
    read -p "Credentials file path (default: $DEFAULT_CREDS_FILE): " CREDS_FILE_INPUT
    CREDS_FILE=${CREDS_FILE_INPUT:-$DEFAULT_CREDS_FILE}

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Configuration Summary:"
    echo "-------------------------------------------------------------------"
    echo "  Subscription:      $AZURE_SUBSCRIPTION"
    echo "  Resource Group:    $AZURE_RESOURCE_GROUP"
    echo "  AI Foundry Name:   $AIFOUNDRY_NAME"
    echo "  Credentials File:  $CREDS_FILE"
    echo "-------------------------------------------------------------------"
    echo ""

    read -p "Proceed with saving credentials? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Operation cancelled."
        exit 0
    fi

    save_aifoundry_credentials "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION" "$CREDS_FILE"
}

# =============================================================================
# Configure Dynatrace Settings via API (LEGACY)
# NOTE: This function is no longer used in the main workflow.
# K8s Experience and Vulnerability Analytics are now configured via dtctl
# in setup-workshop-config.sh. Kept here for standalone/debugging use.
# =============================================================================

configure_dynatrace_settings() {
    local creds_file=$1

    print_header "Configuring Dynatrace Environment Settings"

    # Load credentials
    if [ ! -f "$creds_file" ]; then
        print_warning "Credentials file not found: $creds_file"
        print_warning "Skipping Dynatrace settings configuration"
        return 1
    fi

    local dt_environment_id=$(cat "$creds_file" | jq -r '.DT_ENVIRONMENT_ID // empty')
    local dt_api_token=$(cat "$creds_file" | jq -r '.DT_API_TOKEN // empty')

    if [ -z "$dt_environment_id" ] || [ -z "$dt_api_token" ]; then
        print_warning "DT_ENVIRONMENT_ID or DT_API_TOKEN not found in credentials file"
        print_warning "Skipping Dynatrace settings configuration"
        return 1
    fi

    local dt_api_url="https://${dt_environment_id}.live.dynatrace.com/api/v2/settings/objects"

    # -------------------------------------------------------------------------
    # Enable New Kubernetes Experience
    # -------------------------------------------------------------------------
    echo ""
    echo "Enabling New Kubernetes Experience..."

    K8S_RESPONSE=$(curl -s -X POST "$dt_api_url" \
        -H "Authorization: Api-Token $dt_api_token" \
        -H "Content-Type: application/json" \
        -d '[{
            "schemaId": "builtin:app-transition.kubernetes",
            "scope": "environment",
            "value": {
                "kubernetesAppOptions": {
                    "enableKubernetesApp": true
                }
            }
        }]')

    if echo "$K8S_RESPONSE" | grep -q '"code":200\|"code":201\|objectId'; then
        print_success "New Kubernetes Experience enabled"
    else
        # Check if already enabled (common response)
        if echo "$K8S_RESPONSE" | grep -q "already exists\|constraint-violation"; then
            print_info "New Kubernetes Experience already enabled or constraint exists"
        else
            print_warning "Could not enable New Kubernetes Experience"
            echo "  Response: $(echo "$K8S_RESPONSE" | jq -r '.error.message // .message // .' 2>/dev/null | head -1)"
        fi
    fi

    # -------------------------------------------------------------------------
    # Enable Vulnerability Analytics (Third-Party + Code-Level)
    # The schema requires all properties to be set together
    # -------------------------------------------------------------------------
    echo ""
    echo "Enabling Vulnerability Analytics..."

    # First, check if settings already exist by querying
    EXISTING_SETTINGS=$(curl -s -X GET "${dt_api_url}?schemaIds=builtin:appsec.runtime-vulnerability-detection&scopes=environment" \
        -H "Authorization: Api-Token $dt_api_token" \
        -H "Content-Type: application/json")

    EXISTING_OBJECT_ID=$(echo "$EXISTING_SETTINGS" | jq -r '.items[0].objectId // empty' 2>/dev/null)
    EXISTING_VALUE=$(echo "$EXISTING_SETTINGS" | jq -r '.items[0].value // empty' 2>/dev/null)

    if [ -n "$EXISTING_OBJECT_ID" ] && [ "$EXISTING_OBJECT_ID" != "null" ]; then
        # Settings exist - we need to merge our changes with existing settings

        # Get the current value and merge our changes
        # This preserves any existing 'technologies' array while enabling the features
        MERGED_VALUE=$(echo "$EXISTING_VALUE" | jq '. + {
            "enableRuntimeVulnerabilityDetection": true,
            "globalMonitoringModeTPV": "MONITORING_ON",
            "enableCodeLevelVulnerabilityDetection": true,
            "globalMonitoringModeJava": "MONITORING_ON",
            "globalMonitoringModeDotNet": "MONITORING_ON"
        }' 2>/dev/null)

        # If merge failed, use a default value
        if [ -z "$MERGED_VALUE" ] || [ "$MERGED_VALUE" == "null" ]; then
            MERGED_VALUE='{
                "enableRuntimeVulnerabilityDetection": true,
                "globalMonitoringModeTPV": "MONITORING_ON",
                "enableCodeLevelVulnerabilityDetection": true,
                "globalMonitoringModeJava": "MONITORING_ON",
                "globalMonitoringModeDotNet": "MONITORING_ON"
            }'
        fi

        # Create the full payload for PUT
        PUT_PAYLOAD=$(jq -n \
            --arg schemaId "builtin:appsec.runtime-vulnerability-detection" \
            --arg scope "environment" \
            --argjson value "$MERGED_VALUE" \
            '{schemaId: $schemaId, scope: $scope, value: $value}')

        VA_RESPONSE=$(curl -s -X PUT "${dt_api_url}/${EXISTING_OBJECT_ID}" \
            -H "Authorization: Api-Token $dt_api_token" \
            -H "Content-Type: application/json" \
            -d "$PUT_PAYLOAD")
    else
        # No existing settings, use POST to create

        VA_RESPONSE=$(curl -s -X POST "$dt_api_url" \
            -H "Authorization: Api-Token $dt_api_token" \
            -H "Content-Type: application/json" \
            -d '[{
                "schemaId": "builtin:appsec.runtime-vulnerability-detection",
                "scope": "environment",
                "value": {
                    "enableRuntimeVulnerabilityDetection": true,
                    "globalMonitoringModeTPV": "MONITORING_ON",
                    "enableCodeLevelVulnerabilityDetection": true,
                    "globalMonitoringModeJava": "MONITORING_ON",
                    "globalMonitoringModeDotNet": "MONITORING_ON"
                }
            }]')
    fi

    # Check result
    if echo "$VA_RESPONSE" | grep -q '"code":200\|"code":201\|"code":204\|objectId'; then
        print_success "Vulnerability Analytics enabled (Third-Party + Code-Level)"
    else
        if echo "$VA_RESPONSE" | grep -q "already exists\|constraint-violation"; then
            print_info "Vulnerability Analytics settings already configured"
        else
            # Try to extract a meaningful error message
            ERROR_MSG=$(echo "$VA_RESPONSE" | jq -r '.error.message // .error.constraintViolations[0].message // .message // .' 2>/dev/null | head -1)
            if [ -z "$ERROR_MSG" ] || [ "$ERROR_MSG" == "null" ]; then
                ERROR_MSG="Empty response - check API token scopes (settings.read, settings.write)"
            fi
            print_warning "Could not enable Vulnerability Analytics"
            echo "  Response: $ERROR_MSG"

            # Show hint about required scopes
            echo ""
            print_info "Hint: Ensure your API token has these scopes:"
            echo "  - settings.read"
            echo "  - settings.write"
        fi
    fi

    echo ""
    print_success "Dynatrace settings configuration completed"
    send_dt_event "10-Configure-DT-Settings" ',"status":"Dynatrace settings configured"'
}

# =============================================================================
# Deploy Dynatrace Workshop Configuration (dtctl + Monaco)
# =============================================================================

deploy_monaco_configuration() {
    local creds_file=$1

    print_header "Deploying Dynatrace Workshop Configuration"

    # Load credentials
    if [ ! -f "$creds_file" ]; then
        print_warning "Credentials file not found: $creds_file"
        print_warning "Skipping Dynatrace configuration deployment"
        return 1
    fi

    local dt_environment_id=$(cat "$creds_file" | jq -r '.DT_ENVIRONMENT_ID // empty')
    local dt_api_token=$(cat "$creds_file" | jq -r '.DT_API_TOKEN // empty')

    if [ -z "$dt_environment_id" ] || [ -z "$dt_api_token" ]; then
        print_warning "DT_ENVIRONMENT_ID or DT_API_TOKEN not found in credentials file"
        print_warning "Skipping Dynatrace configuration deployment"
        return 1
    fi

    # Export credentials for dtctl and Monaco
    export DT_BASEURL="https://${dt_environment_id}.live.dynatrace.com"
    export DT_API_TOKEN="$dt_api_token"
    export EMAIL="$EMAIL"
    export DT_ENVIRONMENT_ID="$dt_environment_id"

    # Check if setup-workshop-config.sh exists
    CONFIG_SCRIPT="../workshop-config/setup-workshop-config.sh"
    if [ ! -f "$CONFIG_SCRIPT" ]; then
        print_warning "Workshop config script not found: $CONFIG_SCRIPT"
        print_warning "Skipping Dynatrace configuration deployment"
        return 1
    fi

    echo ""
    echo "Deploying Dynatrace configuration (dtctl + Monaco)..."
    echo "  dtctl (Settings 2.0):"
    echo "    - Auto-tagging rules"
    echo "    - Management Zones"
    echo "    - SLOs"
    echo "    - Kubernetes Experience"
    echo "    - Vulnerability Analytics"
    echo "  Monaco (Classic API):"
    echo "    - Custom Services"
    echo "    - Conditional Naming"
    echo ""

    send_dt_event "11-Deploy-DT-Config" ',"status":"running"'

    # Run the workshop config script (dtctl + Monaco)
    cd ../workshop-config
    ./setup-workshop-config.sh
    CONFIG_RESULT=$?
    cd ../provision-scripts

    if [ $CONFIG_RESULT -eq 0 ]; then
        print_success "Dynatrace configuration deployed successfully"
        send_dt_event "11-Deploy-DT-Config" ',"status":"success"'
    else
        print_warning "Dynatrace configuration completed with some issues"
        send_dt_event "11-Deploy-DT-Config" ',"status":"completed with warnings"'
    fi

    return $CONFIG_RESULT
}

# =============================================================================
# Combined Workshop Configuration (VM + AI Foundry Credentials)
# =============================================================================

configure_workshop_mode() {
    print_header "Configure Workshop Mode"

    echo ""
    echo "This will perform the following steps:"
    echo "  1. Configure VM with workshop repository and open port 80"
    echo "  2. Save AI Foundry credentials to workshop-credentials.json"
    echo "  3. Deploy Dynatrace configuration (dtctl + Monaco)"
    echo "-------------------------------------------------------------------"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    # Get Resource Group Name (with default)
    read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

    # Get VM Name (with default)
    read -p "Virtual Machine Name (default: $DEFAULT_VM_NAME): " VM_NAME_INPUT
    VM_NAME=${VM_NAME_INPUT:-$DEFAULT_VM_NAME}

    # Get AI Foundry Name (with default)
    read -p "AI Foundry Name (default: $DEFAULT_AIFOUNDRY_NAME): " AIFOUNDRY_NAME_INPUT
    AIFOUNDRY_NAME=${AIFOUNDRY_NAME_INPUT:-$DEFAULT_AIFOUNDRY_NAME}

    # Get credentials file path
    DEFAULT_CREDS_FILE="../gen/workshop-credentials.json"
    read -p "Credentials file path (default: $DEFAULT_CREDS_FILE): " CREDS_FILE_INPUT
    CREDS_FILE=${CREDS_FILE_INPUT:-$DEFAULT_CREDS_FILE}

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Configuration Summary:"
    echo "-------------------------------------------------------------------"
    echo "  Subscription:      $AZURE_SUBSCRIPTION"
    echo "  Resource Group:    $AZURE_RESOURCE_GROUP"
    echo "  VM Name:           $VM_NAME"
    echo "  AI Foundry Name:   $AIFOUNDRY_NAME"
    echo "  Credentials File:  $CREDS_FILE"
    echo "-------------------------------------------------------------------"
    echo ""

    read -p "Proceed with workshop configuration? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Configuration cancelled."
        exit 0
    fi

    # Step 1: Configure VM
    echo ""
    echo "=========================================="
    echo "Step 1: Configuring VM"
    echo "=========================================="
    configure_vm_workshop "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION"

    # Step 2: Save AI Foundry Credentials
    echo ""
    echo "=========================================="
    echo "Step 2: Saving AI Foundry Credentials"
    echo "=========================================="
    save_aifoundry_credentials "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION" "$CREDS_FILE"

    # Step 3: Deploy Dynatrace Configuration (dtctl + Monaco)
    echo ""
    echo "=========================================="
    echo "Step 3: Deploying Dynatrace Configuration"
    echo "=========================================="
    deploy_monaco_configuration "$CREDS_FILE"

    echo ""
    print_header "Workshop Configuration Complete"
    echo ""
    echo "Summary:"
    echo "  - VM configured with workshop repository"
    echo "  - Port 80 opened for web traffic"
    echo "  - AI Foundry credentials saved to: $CREDS_FILE"
    echo "  - Dynatrace (via dtctl): K8s Experience, Vulnerability Analytics, Auto-tags, MZs, SLOs"
    echo "  - Dynatrace (via Monaco): Custom Services, Conditional Naming"
    echo ""
}

# =============================================================================
# Summary Output
# =============================================================================

print_summary() {
    print_header "Provisioning Summary"

    echo ""
    echo "Resource Status:"
    echo "-------------------------------------------------------------------"

    # Check final status of each resource
    echo -n "Resource Group [$AZURE_RESOURCE_GROUP]: "
    if [ "$(check_resource_group_exists "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_success "READY"
    else
        print_error "FAILED"
    fi

    echo -n "Virtual Machine [$VM_NAME]: "
    if [ "$(check_vm_exists "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_success "READY"
        VM_IP=$(az vm show --name "$VM_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --show-details --query publicIps --output tsv 2>/dev/null)
        if [ -n "$VM_IP" ]; then
            echo "    Public IP: $VM_IP"
        fi
    else
        print_error "FAILED"
    fi

    echo -n "AKS Cluster [$AKS_CLUSTER_NAME]: "
    if [ "$(check_aks_exists "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_success "READY"
    else
        print_error "FAILED"
    fi

    echo -n "AI Foundry [$AIFOUNDRY_NAME]: "
    if [ "$(check_aifoundry_exists "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_success "READY"
        ENDPOINT=$(az cognitiveservices account show --name "$AIFOUNDRY_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --query "properties.endpoint" --output tsv 2>/dev/null)
        if [ -n "$ENDPOINT" ]; then
            echo "    Endpoint: $ENDPOINT"
        fi
    else
        print_error "FAILED"
    fi

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Provisioning completed at: $(date)"
    echo "-------------------------------------------------------------------"

    # Send completion event
    send_dt_event "06-Provisioning-Complete" ',"status":"All resources provisioned"'
}

# =============================================================================
# Check Only Mode
# =============================================================================

check_only_mode() {
    print_header "Resource Check Mode"

    echo ""
    echo "Checking resources with the following inputs:"
    echo "-------------------------------------------------------------------"

    # Get Azure Subscription ID
    CURRENT_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    read -p "Azure Subscription ID (current: $CURRENT_SUBSCRIPTION): " AZURE_SUBSCRIPTION_INPUT
    AZURE_SUBSCRIPTION=${AZURE_SUBSCRIPTION_INPUT:-$CURRENT_SUBSCRIPTION}

    # Get Resource Group Name (with default)
    read -p "Resource Group Name (default: $DEFAULT_RESOURCE_GROUP): " AZURE_RESOURCE_GROUP_INPUT
    AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP_INPUT:-$DEFAULT_RESOURCE_GROUP}

    # Set hardcoded resource names
    VM_NAME="$DEFAULT_VM_NAME"
    AKS_CLUSTER_NAME="$DEFAULT_AKS_CLUSTER_NAME"
    AIFOUNDRY_NAME="$DEFAULT_AIFOUNDRY_NAME"

    echo ""
    print_header "Resource Status Check Results"

    # Check Resource Group
    echo -n "Resource Group [$AZURE_RESOURCE_GROUP]: "
    if [ "$(check_resource_group_exists "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_success "EXISTS"
        RG_EXISTS=true
    else
        print_warning "NOT FOUND"
        RG_EXISTS=false
    fi

    # Check VM if provided
    if [ -n "$VM_NAME" ]; then
        echo -n "Virtual Machine [$VM_NAME]: "
        if [ "$RG_EXISTS" == "true" ]; then
            if [ "$(check_vm_exists "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
                print_success "EXISTS"
                # Show VM details
                VM_IP=$(az vm show --name "$VM_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --show-details --query publicIps --output tsv 2>/dev/null)
                VM_STATE=$(az vm show --name "$VM_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --show-details --query powerState --output tsv 2>/dev/null)
                echo "    State: $VM_STATE"
                echo "    Public IP: $VM_IP"
            else
                print_warning "NOT FOUND"
            fi
        else
            print_info "Cannot check - Resource Group doesn't exist"
        fi
    fi

    # Check AKS if provided
    if [ -n "$AKS_CLUSTER_NAME" ]; then
        echo -n "AKS Cluster [$AKS_CLUSTER_NAME]: "
        if [ "$RG_EXISTS" == "true" ]; then
            if [ "$(check_aks_exists "$AKS_CLUSTER_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
                print_success "EXISTS"
                # Show AKS details
                AKS_STATE=$(az aks show --name "$AKS_CLUSTER_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --query "powerState.code" --output tsv 2>/dev/null)
                NODE_COUNT=$(az aks show --name "$AKS_CLUSTER_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --query "agentPoolProfiles[0].count" --output tsv 2>/dev/null)
                echo "    State: $AKS_STATE"
                echo "    Node Count: $NODE_COUNT"
            else
                print_warning "NOT FOUND"
            fi
        else
            print_info "Cannot check - Resource Group doesn't exist"
        fi
    fi

    # Check AI Foundry if provided
    if [ -n "$AIFOUNDRY_NAME" ]; then
        echo -n "AI Foundry [$AIFOUNDRY_NAME]: "
        if [ "$RG_EXISTS" == "true" ]; then
            if [ "$(check_aifoundry_exists "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
                print_success "EXISTS"
                # Show AI Foundry details
                ENDPOINT=$(az cognitiveservices account show --name "$AIFOUNDRY_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --query "properties.endpoint" --output tsv 2>/dev/null)
                PROV_STATE=$(az cognitiveservices account show --name "$AIFOUNDRY_NAME" --resource-group "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --query "properties.provisioningState" --output tsv 2>/dev/null)
                echo "    State: $PROV_STATE"
                echo "    Endpoint: $ENDPOINT"
            else
                print_warning "NOT FOUND"
            fi
        else
            print_info "Cannot check - Resource Group doesn't exist"
        fi
    fi

    echo ""
}

# =============================================================================
# Usage Information
# =============================================================================

show_usage() {
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Without options (recommended):"
    echo "  The script auto-detects if resources exist:"
    echo "    - If resources exist: Configures VM and saves credentials"
    echo "    - If resources don't exist: Creates them, then configures"
    echo ""
    echo "Options:"
    echo "  --check                 Check if resources exist without creating them"
    echo "  --configure-workshop    Configure VM + save AI Foundry creds (interactive)"
    echo "  --configure-vm          Configure VM only (clone repo, open port 80)"
    echo "  --save-aifoundry-creds  Save AI Foundry credentials only"
    echo "  --help                  Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                       # Auto-detect and setup (recommended)"
    echo "  $0 --check               # Check resource existence only"
    echo "  $0 --configure-workshop  # Re-configure workshop (interactive prompts)"
    echo ""
}

# =============================================================================
# Run Workshop Configuration (non-interactive - uses global variables)
# =============================================================================

run_workshop_configuration() {
    print_header "Configuring Workshop Environment"

    echo ""
    echo "This will perform the following steps:"
    echo "  1. Configure VM with workshop repository, Docker, and start monolith app"
    echo "  2. Save AI Foundry credentials to workshop-credentials.json"
    echo "  3. Deploy Dynatrace configuration (dtctl + Monaco)"
    echo ""

    # Use defaults
    DEFAULT_CREDS_FILE="../gen/workshop-credentials.json"

    # Step 1: Configure VM
    echo "=========================================="
    echo "Step 1: Configuring VM"
    echo "=========================================="
    configure_vm_workshop "$VM_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION"

    # Step 2: Save AI Foundry Credentials (also updates Travel Advisor manifest)
    echo ""
    echo "=========================================="
    echo "Step 2: Saving AI Foundry Credentials"
    echo "=========================================="
    save_aifoundry_credentials "$AIFOUNDRY_NAME" "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION" "$DEFAULT_CREDS_FILE"

    # Step 3: Deploy Dynatrace Configuration (dtctl + Monaco)
    echo ""
    echo "=========================================="
    echo "Step 3: Deploying Dynatrace Configuration"
    echo "=========================================="
    deploy_monaco_configuration "$DEFAULT_CREDS_FILE"

    echo ""
    print_header "Workshop Configuration Complete"
    echo ""
    echo "Summary:"
    echo "  - VM configured with workshop repository and Docker"
    echo "  - Monolith application started"
    echo "  - Port 80 opened for web traffic"
    echo "  - AI Foundry credentials saved to: $DEFAULT_CREDS_FILE"
    echo "  - Travel Advisor manifest updated with credentials"
    echo "  - Dynatrace (via dtctl): K8s Experience, Vulnerability Analytics, Auto-tags, MZs, SLOs"
    echo "  - Dynatrace (via Monaco): Custom Services, Conditional Naming"
    echo ""
}

# =============================================================================
# Quick Check Resources with Defaults (no user input)
# =============================================================================

quick_check_resources_with_defaults() {
    # Set defaults
    AZURE_SUBSCRIPTION=$(az account show --query id --output tsv 2>/dev/null)
    AZURE_RESOURCE_GROUP="$DEFAULT_RESOURCE_GROUP"
    VM_NAME="$DEFAULT_VM_NAME"
    AKS_CLUSTER_NAME="$DEFAULT_AKS_CLUSTER_NAME"
    AIFOUNDRY_NAME="$DEFAULT_AIFOUNDRY_NAME"

    # Load Dynatrace credentials from workshop-credentials.json if available
    CREDS_FILE="../gen/workshop-credentials.json"
    if [ -f "$CREDS_FILE" ]; then
        DT_ENVIRONMENT_ID=$(cat "$CREDS_FILE" | jq -r '.DT_ENVIRONMENT_ID // empty')
        EMAIL=$(cat "$CREDS_FILE" | jq -r '.EMAIL // empty')
    fi

    # Derive email from Azure CLI if not loaded from creds file
    if [ -z "$EMAIL" ]; then
        EMAIL=$(az account show --query user.name --output tsv 2>/dev/null)
        EMAIL=$(echo $EMAIL | cut -d'#' -f 2)
    fi

    print_header "Checking for Existing Workshop Resources"
    echo ""
    echo "Using default resource names:"
    echo "  Resource Group: $AZURE_RESOURCE_GROUP"
    echo "  VM:             $VM_NAME"
    echo "  AKS Cluster:    $AKS_CLUSTER_NAME"
    echo "  AI Foundry:     $AIFOUNDRY_NAME"
    echo ""

    # Check Resource Group
    echo -n "Resource Group [$AZURE_RESOURCE_GROUP]: "
    if [ "$(check_resource_group_exists "$AZURE_RESOURCE_GROUP" "$AZURE_SUBSCRIPTION")" == "true" ]; then
        print_success "EXISTS"
        RG_EXISTS=true
        # Get location from existing resource group (avoids asking user later)
        AZURE_LOCATION=$(az group show --name "$AZURE_RESOURCE_GROUP" --subscription "$AZURE_SUBSCRIPTION" --query location --output tsv 2>/dev/null)
    else
        print_warning "NOT FOUND"
        RG_EXISTS=false
        AZURE_LOCATION=""
    fi

    # Check VM
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

    echo ""
}

# =============================================================================
# Main Script Execution
# =============================================================================

main() {
    # Check for --help first (doesn't require credentials)
    if [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
        show_usage
        exit 0
    fi

    # Check prerequisites before any operation
    check_prerequisites

    # Parse command line arguments
    case "$1" in
        --check)
            check_only_mode
            exit 0
            ;;
        --configure-workshop)
            configure_workshop_mode
            exit 0
            ;;
        --configure-vm)
            configure_vm_mode
            exit 0
            ;;
        --save-aifoundry-creds)
            save_aifoundry_creds_mode
            exit 0
            ;;
        --help|-h)
            show_usage
            exit 0
            ;;
        "")
            # Auto-detect mode - check resources first, then decide
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac

    # =========================================================================
    # AUTO-DETECT MODE: Check if resources exist with defaults first
    # =========================================================================

    print_header "Azure Workshop Setup Script"
    echo ""
    echo "This script will:"
    echo "  - Check if workshop resources already exist"
    echo "  - If resources exist: Configure VM and save credentials"
    echo "  - If resources don't exist: Create them, then configure"
    echo ""

    # Quick check with defaults (no user input needed)
    quick_check_resources_with_defaults

    # =========================================================================
    # SCENARIO 1: All resources exist - just run configuration
    # =========================================================================
    if [ "$RG_EXISTS" == "true" ] && [ "$VM_EXISTS" == "true" ] && [ "$AKS_EXISTS" == "true" ] && [ "$AIFOUNDRY_EXISTS" == "true" ]; then
        print_header "All Resources Already Exist"
        echo ""
        print_success "All Azure resources are already provisioned!"
        echo ""
        echo "Proceeding to configure the workshop environment..."
        echo ""

        read -p "Continue with workshop configuration? (y/n): " CONFIRM
        if [ "$CONFIRM" != "y" ]; then
            echo "Setup cancelled."
            exit 0
        fi

        # Run configuration with defaults
        run_workshop_configuration

        # Print final summary
        print_summary
        send_dt_event "99-Workshop-setup-complete" ',"status":"Success","scenario":"All resources existed"'
        exit 0
    fi

    # =========================================================================
    # SCENARIO 2: Some or all resources missing - need to provision first
    # =========================================================================
    print_header "Resources Need to be Provisioned"
    echo ""
    echo "The following resources need to be created:"
    [ "$RG_EXISTS" == "false" ] && echo "  - Resource Group: $AZURE_RESOURCE_GROUP"
    [ "$VM_EXISTS" == "false" ] && echo "  - Virtual Machine: $VM_NAME"
    [ "$AKS_EXISTS" == "false" ] && echo "  - AKS Cluster: $AKS_CLUSTER_NAME"
    [ "$AIFOUNDRY_EXISTS" == "false" ] && echo "  - AI Foundry: $AIFOUNDRY_NAME"
    echo ""

    # Only ask for location if resource group doesn't exist
    if [ "$RG_EXISTS" == "false" ]; then
        read -p "Azure Location for new resources (default: $DEFAULT_LOCATION): " AZURE_LOCATION_INPUT
        AZURE_LOCATION=${AZURE_LOCATION_INPUT:-$DEFAULT_LOCATION}
    else
        echo "Using existing resource group location: $AZURE_LOCATION"
    fi

    echo ""
    echo "-------------------------------------------------------------------"
    echo "Configuration Summary:"
    echo "-------------------------------------------------------------------"
    echo "  Subscription:      $AZURE_SUBSCRIPTION"
    echo "  Resource Group:    $AZURE_RESOURCE_GROUP"
    echo "  Location:          $AZURE_LOCATION"
    echo "-------------------------------------------------------------------"
    echo ""

    read -p "Proceed with provisioning? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo "Provisioning cancelled."
        exit 0
    fi

    # Register required resource providers
    register_resource_providers

    # Create resources
    echo ""
    echo "Starting resource provisioning at: $(date)"
    echo ""

    create_resource_group
    if [ $? -ne 0 ]; then
        print_error "Aborting due to Resource Group creation failure."
        exit 1
    fi

    create_virtual_machine

    create_aks_cluster

    create_ai_foundry

    # Print provisioning summary
    print_summary

    # =========================================================================
    # After provisioning, automatically run workshop configuration
    # =========================================================================
    echo ""
    print_header "Provisioning Complete - Starting Workshop Configuration"
    echo ""
    echo "Now configuring the workshop environment..."
    echo ""

    # Run configuration
    run_workshop_configuration

    echo ""
    print_header "Workshop Setup Complete!"
    send_dt_event "99-Workshop-setup-complete" ',"status":"Success","scenario":"Resources provisioned and configured"'
    echo ""
}

# Run main function
main "$@"
