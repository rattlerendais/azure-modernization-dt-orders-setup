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

    # Optional: Dynatrace event tracking
    echo ""
    echo "Optional: Dynatrace Event Tracking (press Enter to skip)"
    read -p "Dynatrace Environment ID (e.g., abc12345): " DT_ENV_INPUT
    DT_ENVIRONMENT_ID=${DT_ENV_INPUT:-""}

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
        send_dt_event "02-Create-resource-group" ',"status":"Already exists"'
        return 0
    fi

    echo "Creating resource group in $AZURE_LOCATION..."
    az group create \
        --name "$AZURE_RESOURCE_GROUP" \
        --location "$AZURE_LOCATION" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --tags "CreatedBy=provision-azure-resources" \
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
        send_dt_event "03-Provision-VM" ',"vmState":"Already exists"'
        return 0
    fi

    echo "Creating VM with the following configuration:"
    echo "  - Size: $DEFAULT_VM_SIZE"
    echo "  - Image: Ubuntu 22.04 LTS"
    echo "  - Admin User: $VM_ADMIN_USERNAME"
    echo ""

    # Capture both stdout and stderr for better error reporting
    # Explicitly name network resources to avoid conflicts with orphaned resources
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
        --tags "Owner=azure-modernize-workshop" \
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
        send_dt_event "04-Create-AKS-cluster" ',"status":"Already exists"'
        return 0
    fi

    echo "Creating AKS Cluster with the following configuration:"
    echo "  - Node Count: $DEFAULT_AKS_NODE_COUNT"
    echo "  - Node Size: $DEFAULT_AKS_NODE_SIZE"
    echo "  - OS: Azure Linux"
    echo ""
    echo "This may take several minutes..."

    az aks create \
        --name "$AKS_CLUSTER_NAME" \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --subscription "$AZURE_SUBSCRIPTION" \
        --node-count $DEFAULT_AKS_NODE_COUNT \
        --node-vm-size "$DEFAULT_AKS_NODE_SIZE" \
        --os-sku AzureLinux \
        --enable-addons monitoring \
        --generate-ssh-keys \
        --tags "CreatedBy=provision-azure-resources" \
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
        --tags "CreatedBy=provision-azure-resources" \
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
    else
        print_warning "VM configuration completed. Output:"
        echo "$RESULT"
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
        return 1
    fi

    echo "Fetching AI Foundry endpoint and API key for: $aifoundry_name"

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
        return 1
    fi

    if [ -z "$AZURE_AIFOUNDRY_MODEL_KEY" ]; then
        print_error "Could not retrieve AI Foundry API key"
        return 1
    fi

    print_success "Retrieved AI Foundry credentials"
    echo "  Endpoint: $AZURE_AIFOUNDRY_ENDPOINT"
    echo "  API Key: [REDACTED]"

    # Check if credentials file exists
    if [ ! -f "$creds_file" ]; then
        print_warning "Credentials file not found: $creds_file"
        echo "Creating new credentials file..."
        # Create a minimal JSON file
        echo '{}' > "$creds_file"
    fi

    # Update the credentials file using jq
    echo ""
    echo "Updating $creds_file with AI Foundry credentials..."
    TEMP_FILE=$(mktemp)
    jq --arg endpoint "$AZURE_AIFOUNDRY_ENDPOINT" \
       --arg key "$AZURE_AIFOUNDRY_MODEL_KEY" \
       --arg name "$aifoundry_name" \
       '.AZURE_AIFOUNDRY_ENDPOINT = $endpoint | .AZURE_AIFOUNDRY_MODEL_KEY = $key | .AZURE_AIFOUNDRY_NAME = $name' \
       "$creds_file" > "$TEMP_FILE" && mv "$TEMP_FILE" "$creds_file"

    if [ $? -eq 0 ]; then
        print_success "Credentials file updated successfully: $creds_file"
    else
        print_error "Failed to update credentials file"
        return 1
    fi
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
# Combined Workshop Configuration (VM + AI Foundry Credentials)
# =============================================================================

configure_workshop_mode() {
    print_header "Configure Workshop Mode"

    echo ""
    echo "This will perform the following steps:"
    echo "  1. Configure VM with workshop repository and open port 80"
    echo "  2. Save AI Foundry credentials to workshop-credentials.json"
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

    echo ""
    print_header "Workshop Configuration Complete"
    echo ""
    echo "Summary:"
    echo "  - VM configured with workshop repository"
    echo "  - Port 80 opened for web traffic"
    echo "  - AI Foundry credentials saved to: $CREDS_FILE"
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
    echo "Options:"
    echo "  --check                 Check if resources exist without creating them"
    echo "  --configure-workshop    Configure VM + save AI Foundry creds (run after provisioning)"
    echo "  --configure-vm          Configure VM only (clone repo, open port 80)"
    echo "  --save-aifoundry-creds  Save AI Foundry credentials only"
    echo "  --help                  Show this help message"
    echo ""
    echo "Without options, the script will interactively gather inputs and"
    echo "create all resources (Resource Group, VM, AKS, AI Foundry)."
    echo ""
    echo "Examples:"
    echo "  $0                       # Interactive provisioning mode"
    echo "  $0 --check               # Check resource existence only"
    echo "  $0 --configure-workshop  # Configure VM + save AI Foundry creds (recommended)"
    echo "  $0 --configure-vm        # Configure VM only"
    echo "  $0 --save-aifoundry-creds  # Save AI Foundry credentials only"
    echo ""
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
            # Interactive provisioning mode
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac

    # Gather inputs interactively
    gather_inputs

    # Check current resource status
    check_all_resources_status

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

    # Print final summary
    print_summary
}

# Run main function
main "$@"
