#!/bin/bash

# =============================================================================
# dtctl Setup Script
# =============================================================================
# Downloads and configures dtctl for Dynatrace Platform API access
# Used for uploading notebooks and managing platform resources
# =============================================================================

# Change to script directory
cd "$(dirname "$0")"

source ./_workshop-config.lib 2>/dev/null || true

# dtctl version to download
DTCTL_VERSION="0.10.0"

# Detect OS and architecture
detect_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64|amd64)
            ARCH="amd64"
            ;;
        aarch64|arm64)
            ARCH="arm64"
            ;;
        *)
            echo "ERROR: Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    case "$OS" in
        darwin)
            OS="darwin"
            ;;
        linux)
            OS="linux"
            ;;
        mingw*|msys*|cygwin*)
            OS="windows"
            ;;
        *)
            echo "ERROR: Unsupported OS: $OS"
            exit 1
            ;;
    esac

    echo "${OS}_${ARCH}"
}

# Download dtctl binary
download_dtctl() {
    local PLATFORM=$(detect_platform)
    local BINARY_NAME="dtctl"
    local ARCHIVE_EXT="tar.gz"

    if [[ "$PLATFORM" == windows_* ]]; then
        BINARY_NAME="dtctl.exe"
        ARCHIVE_EXT="zip"
    fi

    local DOWNLOAD_URL="https://github.com/dynatrace-oss/dtctl/releases/download/v${DTCTL_VERSION}/dtctl_${DTCTL_VERSION}_${PLATFORM}.${ARCHIVE_EXT}"

    echo "Downloading dtctl v${DTCTL_VERSION} for ${PLATFORM}..."
    echo "  URL: $DOWNLOAD_URL"

    # Download to temp file
    local TEMP_FILE="/tmp/dtctl_download.${ARCHIVE_EXT}"

    if ! curl -sL -o "$TEMP_FILE" "$DOWNLOAD_URL"; then
        echo "ERROR: Failed to download dtctl"
        return 1
    fi

    # Extract binary
    if [[ "$ARCHIVE_EXT" == "zip" ]]; then
        unzip -o -q "$TEMP_FILE" "$BINARY_NAME" -d .
    else
        tar -xzf "$TEMP_FILE" "$BINARY_NAME" 2>/dev/null || tar -xzf "$TEMP_FILE" -C . "$BINARY_NAME"
    fi

    # Make executable (non-Windows)
    if [[ "$PLATFORM" != windows_* ]]; then
        chmod +x "$BINARY_NAME"
    fi

    # Cleanup
    rm -f "$TEMP_FILE"

    # Verify
    if [ -f "$BINARY_NAME" ]; then
        echo "  Downloaded: ./$BINARY_NAME"
        ./$BINARY_NAME version 2>/dev/null || true
        return 0
    else
        echo "ERROR: dtctl binary not found after extraction"
        return 1
    fi
}

# Configure dtctl context
configure_dtctl() {
    echo ""
    echo "Configuring dtctl context..."

    # Check required environment variables
    if [ -z "$DT_BASEURL_PLATFORM" ] || [ -z "$DT_PLATFORM_TOKEN" ]; then
        echo "ERROR: DT_BASEURL_PLATFORM and DT_PLATFORM_TOKEN must be set"
        echo "Make sure to source the workshop credentials first"
        return 1
    fi

    # Set context
    ./dtctl config set-context workshop \
        --environment "$DT_BASEURL_PLATFORM" \
        --token-ref workshop-token \
        --safety-level readwrite-all \
        --description "Azure Workshop Environment"

    # Set credentials
    ./dtctl config set-credentials workshop-token \
        --token "$DT_PLATFORM_TOKEN"

    # Use the context
    ./dtctl config use-context workshop

    echo ""
    echo "dtctl configured successfully!"
    echo ""

    # Verify connection
    echo "Verifying connection..."
    if ./dtctl auth whoami 2>/dev/null; then
        echo ""
        echo "Connection verified!"
        return 0
    else
        echo ""
        echo "WARNING: Could not verify connection. Token may be invalid."
        return 1
    fi
}

# Main
echo "==========================================================="
echo "dtctl Setup"
echo "==========================================================="
echo "  Version: $DTCTL_VERSION"
echo ""

# Download if not exists or force flag
if [ ! -f "./dtctl" ] && [ ! -f "./dtctl.exe" ] || [ "$1" == "--force" ]; then
    download_dtctl || exit 1
else
    echo "dtctl already exists. Use --force to re-download."
fi

# Configure if credentials are available
if [ -n "$DT_BASEURL_PLATFORM" ] && [ -n "$DT_PLATFORM_TOKEN" ]; then
    configure_dtctl
else
    echo ""
    echo "Skipping configuration (credentials not set)."
    echo "To configure manually, run:"
    echo "  ./dtctl config set-context workshop --environment \$DT_BASEURL_PLATFORM --token-ref workshop-token"
    echo "  ./dtctl config set-credentials workshop-token --token \$DT_PLATFORM_TOKEN"
fi

echo ""
echo "==========================================================="
echo "dtctl Setup Complete!"
echo "==========================================================="
echo ""
echo "Usage examples:"
echo "  ./dtctl get notebooks                    # List notebooks"
echo "  ./dtctl get dashboards                   # List dashboards"
echo "  ./dtctl apply -f notebook.yaml           # Upload notebook"
echo "  ./dtctl query 'fetch logs | limit 10'   # Run DQL query"
echo ""
