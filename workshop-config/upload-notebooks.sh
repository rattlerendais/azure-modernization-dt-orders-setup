#!/bin/bash

# =============================================================================
# Upload Notebooks Script
# =============================================================================
# Uploads workshop notebooks to Dynatrace using dtctl
# =============================================================================

# Change to script directory
cd "$(dirname "$0")"

source ./_workshop-config.lib 2>/dev/null || true

NOTEBOOKS_DIR="./notebooks"

echo "==========================================================="
echo "Upload Workshop Notebooks"
echo "==========================================================="
echo "  Environment: $DT_BASEURL_PLATFORM"
echo "  Notebooks:   $NOTEBOOKS_DIR"
echo ""

# Check if dtctl exists
if [ ! -f "./dtctl" ] && [ ! -f "./dtctl.exe" ]; then
    echo "ERROR: dtctl not found. Run setup-dtctl.sh first."
    exit 1
fi

# Determine dtctl binary name
DTCTL="./dtctl"
if [ -f "./dtctl.exe" ]; then
    DTCTL="./dtctl.exe"
fi

# Check if notebooks directory exists
if [ ! -d "$NOTEBOOKS_DIR" ]; then
    echo "ERROR: Notebooks directory not found: $NOTEBOOKS_DIR"
    exit 1
fi

# Count notebooks
NOTEBOOK_COUNT=$(find "$NOTEBOOKS_DIR" -name "*.yaml" -o -name "*.yml" 2>/dev/null | wc -l)
if [ "$NOTEBOOK_COUNT" -eq 0 ]; then
    echo "No notebooks found in $NOTEBOOKS_DIR"
    exit 0
fi

echo "Found $NOTEBOOK_COUNT notebook(s) to upload"
echo ""

# Upload each notebook
ERRORS=0
for notebook in "$NOTEBOOKS_DIR"/*.yaml "$NOTEBOOKS_DIR"/*.yml; do
    # Skip if no match (glob didn't expand)
    [ -e "$notebook" ] || continue

    NOTEBOOK_NAME=$(basename "$notebook")
    echo -n "  Uploading: $NOTEBOOK_NAME... "

    # Use dtctl apply to create or update
    if $DTCTL apply -f "$notebook" 2>/dev/null; then
        echo "OK"
    else
        echo "FAILED"
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
