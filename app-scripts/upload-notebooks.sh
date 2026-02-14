#!/bin/bash

# =============================================================================
# Upload Notebooks Script
# =============================================================================
# Uploads workshop notebooks to Dynatrace using the Documents API
# =============================================================================

# Change to script directory
cd "$(dirname "$0")"

source ../provision-scripts/_provision-scripts.lib 2>/dev/null || true

NOTEBOOKS_DIR="./resources"

# Load credentials
CREDS_FILE="../gen/workshop-credentials.json"
if [ -f "$CREDS_FILE" ]; then
    DT_BASEURL_PLATFORM=$(cat "$CREDS_FILE" | jq -r '.DT_BASEURL_PLATFORM // empty')
    DT_PLATFORM_TOKEN=$(cat "$CREDS_FILE" | jq -r '.DT_PLATFORM_TOKEN // empty')
fi

if [ -z "$DT_BASEURL_PLATFORM" ] || [ -z "$DT_PLATFORM_TOKEN" ]; then
    echo "ERROR: Missing Dynatrace credentials. Run input-credentials.sh first."
    exit 1
fi

echo "==========================================================="
echo "Upload Workshop Notebooks"
echo "==========================================================="
echo "  Environment: $DT_BASEURL_PLATFORM"
echo "  Notebooks:   $NOTEBOOKS_DIR"
echo ""

# Check if notebooks directory exists
if [ ! -d "$NOTEBOOKS_DIR" ]; then
    echo "ERROR: Notebooks directory not found: $NOTEBOOKS_DIR"
    exit 1
fi

# Count notebooks
NOTEBOOK_COUNT=$(find "$NOTEBOOKS_DIR" -name "*.json" 2>/dev/null | wc -l)
if [ "$NOTEBOOK_COUNT" -eq 0 ]; then
    echo "No notebooks found in $NOTEBOOKS_DIR"
    exit 0
fi

echo "Found $NOTEBOOK_COUNT notebook(s) to upload"
echo ""

# Upload each notebook
ERRORS=0
for notebook in "$NOTEBOOKS_DIR"/*.json; do
    # Skip if no match (glob didn't expand)
    [ -e "$notebook" ] || continue

    NOTEBOOK_NAME=$(basename "$notebook" .json)
    echo -n "  Uploading: $NOTEBOOK_NAME... "

    # Read notebook content
    NOTEBOOK_CONTENT=$(cat "$notebook")

    # Create the document payload
    # The Documents API expects: name, type, content, isPrivate
    PAYLOAD=$(jq -n \
        --arg name "$NOTEBOOK_NAME" \
        --arg content "$NOTEBOOK_CONTENT" \
        '{
            "name": $name,
            "type": "notebook",
            "isPrivate": false,
            "content": $content
        }')

    # Upload using Documents API
    RESPONSE=$(curl -s -w "\n%{http_code}" \
        -X POST "${DT_BASEURL_PLATFORM}/platform/document/v1/documents" \
        -H "Authorization: Bearer $DT_PLATFORM_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$PAYLOAD" 2>/dev/null)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" == "201" ] || [ "$HTTP_CODE" == "200" ]; then
        echo "OK"
    elif [ "$HTTP_CODE" == "409" ]; then
        # Document already exists, try to update it
        # First, find the document ID
        EXISTING=$(curl -s \
            "${DT_BASEURL_PLATFORM}/platform/document/v1/documents?filter=name%3D%3D%27${NOTEBOOK_NAME}%27%26type%3D%3D%27notebook%27" \
            -H "Authorization: Bearer $DT_PLATFORM_TOKEN" 2>/dev/null)

        DOC_ID=$(echo "$EXISTING" | jq -r '.documents[0].id // empty')

        if [ -n "$DOC_ID" ]; then
            # Update existing document
            UPDATE_RESPONSE=$(curl -s -w "\n%{http_code}" \
                -X PUT "${DT_BASEURL_PLATFORM}/platform/document/v1/documents/${DOC_ID}" \
                -H "Authorization: Bearer $DT_PLATFORM_TOKEN" \
                -H "Content-Type: application/json" \
                -d "$PAYLOAD" 2>/dev/null)

            UPDATE_CODE=$(echo "$UPDATE_RESPONSE" | tail -n1)

            if [ "$UPDATE_CODE" == "200" ]; then
                echo "UPDATED"
            else
                echo "FAILED (update: HTTP $UPDATE_CODE)"
                ((ERRORS++))
            fi
        else
            echo "FAILED (exists but couldn't find ID)"
            ((ERRORS++))
        fi
    else
        echo "FAILED (HTTP $HTTP_CODE)"
        ((ERRORS++))
    fi
done

echo ""
echo "==========================================================="
if [ $ERRORS -eq 0 ]; then
    echo "All notebooks uploaded successfully!"
else
    echo "Completed with $ERRORS error(s)"
fi
echo "==========================================================="
echo ""
echo "View notebooks in Dynatrace:"
echo "  $DT_BASEURL_PLATFORM/ui/document/list?filter-documentType=notebook"
echo ""
