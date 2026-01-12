#!/bin/bash

################################################################################
# Docker Volume Restore Script
# Version: 1.1.0
# Description: Restore Docker volumes from a backup package
################################################################################

set -euo pipefail

PACKAGE_FILE="$1"
RESTORE_DIR="restore_temp_$(date +%s)"
RESTORE_SUFFIX="_restored"

show_usage() {
    cat << EOF
Usage: $(basename "$0") <package_file.tar.gz> [OPTIONS]

Restore Docker volumes from a backup package.

ARGUMENTS:
    package_file.tar.gz    Path to the backup package file

OPTIONS:
    --no-suffix            Don't add '_restored' suffix to volume names
                          (will restore to original volume names - USE WITH CAUTION!)
    --help                 Display this help message

EXAMPLES:
    $(basename "$0") wordpress-prod_package_20251219_143015.tar.gz
    $(basename "$0") wordpress-prod_package_20251219_143015.tar.gz --no-suffix

NOTES:
    - By default, volumes are restored with '_restored' suffix for safety
    - Use --no-suffix to restore to original volume names (stops containers first!)
    - Always test restores before applying to production
    - Check the manifest file in the extracted package for volume list

EOF
}

# Parse arguments
if [[ -z "${1:-}" ]] || [[ "$1" == "--help" ]]; then
    show_usage
    exit 0
fi

# Check for --no-suffix flag
NO_SUFFIX=false
if [[ "${2:-}" == "--no-suffix" ]]; then
    NO_SUFFIX=true
    echo "WARNING: Restoring to original volume names. This will replace existing volumes!"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo "Restore cancelled."
        exit 0
    fi
fi

# Check if package file exists
if [[ ! -f "$PACKAGE_FILE" ]]; then
    echo "Error: Package file not found: $PACKAGE_FILE"
    exit 1
fi

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed or not in PATH"
    exit 1
fi

echo "=============================================="
echo "Docker Volume Restore Script"
echo "=============================================="
echo "Package: $PACKAGE_FILE"
echo "Restore directory: $RESTORE_DIR"
if [[ "$NO_SUFFIX" == true ]]; then
    echo "Mode: Replace original volumes"
else
    echo "Mode: Create new volumes with '$RESTORE_SUFFIX' suffix"
fi
echo ""

# Create restore directory
mkdir -p "$RESTORE_DIR"
echo "[1/4] Extracting backup package..."
tar xzf "$PACKAGE_FILE" -C "$RESTORE_DIR/"

# Change to restore directory
cd "$RESTORE_DIR"

# Show manifest if it exists
if ls manifest_*.txt 1> /dev/null 2>&1; then
    echo ""
    echo "=== Backup Manifest ==="
    cat manifest_*.txt
    echo ""
fi

echo "[2/4] Found the following volume backups:"
volume_count=0
for volume_backup in *_*.tar.gz; do
    # Skip if it's a package file
    [[ "$volume_backup" == *"_package_"* ]] && continue
    [[ ! -f "$volume_backup" ]] && continue

    volume_count=$((volume_count + 1))
    size=$(du -h "$volume_backup" | cut -f1)
    echo "  [$volume_count] $volume_backup ($size)"
done

if [[ $volume_count -eq 0 ]]; then
    echo "Error: No volume backups found in package!"
    exit 1
fi

echo ""
echo "[3/4] Restoring volumes..."
echo ""

restored_count=0
failed_count=0

for volume_backup in *_*.tar.gz; do
    # Skip if it's a package file
    [[ "$volume_backup" == *"_package_"* ]] && continue
    [[ ! -f "$volume_backup" ]] && continue

    # Extract volume name from filename
    # Format: site_id_volume_name_timestamp.tar.gz
    # We want just the volume_name part
    volume_name=$(echo "$volume_backup" | sed -E 's/^[^_]+_(.+)_[0-9]{8}_[0-9]{6}\.tar\.gz$/\1/')

    if [[ "$NO_SUFFIX" == true ]]; then
        target_volume="$volume_name"

        # Check if volume exists and remove it
        if docker volume inspect "$target_volume" &>/dev/null; then
            echo "  Removing existing volume: $target_volume"
            docker volume rm "$target_volume" 2>/dev/null || {
                echo "  ✗ Failed to remove volume (may be in use)"
                failed_count=$((failed_count + 1))
                continue
            }
        fi
    else
        target_volume="${volume_name}${RESTORE_SUFFIX}"
    fi

    echo "  Restoring: $volume_name -> $target_volume"

    # Create target volume
    if ! docker volume create "$target_volume" &>/dev/null; then
        echo "  ✗ Failed to create volume: $target_volume"
        failed_count=$((failed_count + 1))
        continue
    fi

    # Restore data
    if docker run --rm \
        -v "${target_volume}:/target" \
        -v "$(pwd):/backup" \
        alpine:latest \
        tar xzf "/backup/$volume_backup" -C /target 2>/dev/null; then
        echo "  ✓ Successfully restored: $target_volume"
        restored_count=$((restored_count + 1))
    else
        echo "  ✗ Failed to restore: $target_volume"
        failed_count=$((failed_count + 1))
    fi
done

echo ""
echo "[4/4] Restoration Summary"
echo "  Successful: $restored_count"
echo "  Failed: $failed_count"
echo ""

if [[ $restored_count -gt 0 ]]; then
    echo "Restored volumes:"
    docker volume ls | grep -E "$(if [[ "$NO_SUFFIX" == false ]]; then echo "$RESTORE_SUFFIX"; else echo ".*"; fi)"
    echo ""
fi

# Cleanup instructions
echo "=============================================="
if [[ "$NO_SUFFIX" == true ]]; then
    echo "Restoration complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Start your containers: docker-compose up -d"
    echo "  2. Verify data integrity"
    echo "  3. Clean up restore directory: rm -rf $(pwd)"
else
    echo "Restoration complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify restored data in volumes with '$RESTORE_SUFFIX' suffix"
    echo "  2. If data looks good, stop your containers and swap volumes:"
    echo "     docker-compose down"
    echo "     docker volume rm <original_volume>"
    echo "     docker volume create <original_volume>"
    echo "     # Then restore again with --no-suffix flag"
    echo "  3. Clean up restore directory: rm -rf $(pwd)"
fi
echo "=============================================="
