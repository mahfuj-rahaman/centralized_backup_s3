#!/bin/bash

################################################################################
# Docker Volume Backup Script
# Version: 1.1.0
# Description: Centralized backup system for Docker volumes with S3 upload
#              and configurable retention policies.
#              All volumes for a site are packaged together into a single
#              compressed archive for easier management and restoration.
################################################################################

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default configuration
CONFIG_FILE="${BACKUP_CONFIG_FILE:-${SCRIPT_DIR}/config.json}"
DRY_RUN=false
SPECIFIC_SITE=""
LOG_FILE=""

# Global variables (populated from config)
BACKUP_BASE_DIR=""
LOG_DIR=""
S3_ENDPOINT=""
S3_REGION=""
TEMP_CLEANUP=""

# Version
VERSION="1.1.0"

################################################################################
# Logging Functions
################################################################################

setup_logging() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    LOG_FILE="${LOG_DIR}/backup_${timestamp}.log"

    # Create log directory if it doesn't exist
    mkdir -p "$LOG_DIR"

    # Create log file
    touch "$LOG_FILE"

    log_info "==================================================="
    log_info "Docker Volume Backup Script v${VERSION}"
    log_info "Started at: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "==================================================="
}

log_info() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE"
    else
        echo "$message"
    fi
}

log_error() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE" >&2
    else
        echo "$message" >&2
    fi
}

log_success() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE"
    else
        echo "$message"
    fi
}

log_warning() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [WARNING] $*"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$message" | tee -a "$LOG_FILE"
    else
        echo "$message"
    fi
}

################################################################################
# Utility Functions
################################################################################

show_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Centralized Docker volume backup script with S3 upload support.

OPTIONS:
    --config FILE       Path to configuration file (default: ./config.json)
    --site SITE_ID      Backup only specific site by site_id
    --dry-run           Show what would be done without executing
    --help              Display this help message
    --version           Show version information

EXAMPLES:
    $(basename "$0")                              # Backup all enabled sites
    $(basename "$0") --config /etc/backup/config.json
    $(basename "$0") --site wordpress-prod        # Backup single site
    $(basename "$0") --dry-run                    # Test without executing

ENVIRONMENT VARIABLES:
    AWS_ACCESS_KEY_ID           Wasabi/AWS access key
    AWS_SECRET_ACCESS_KEY       Wasabi/AWS secret key
    AWS_DEFAULT_REGION          AWS region (default: us-east-1)
    BACKUP_CONFIG_FILE          Override default config file path

EOF
}

get_timestamp() {
    date +%Y%m%d_%H%M%S
}

check_dependencies() {
    log_info "Checking dependencies..."

    local missing_deps=()

    # Check for Docker
    if ! command -v docker &> /dev/null; then
        missing_deps+=("docker")
    fi

    # Check for jq
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi

    # Check for AWS CLI
    if ! command -v aws &> /dev/null; then
        missing_deps+=("aws")
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install missing dependencies:"
        for dep in "${missing_deps[@]}"; do
            case $dep in
                docker)
                    log_info "  - Docker: https://docs.docker.com/get-docker/"
                    ;;
                jq)
                    log_info "  - jq: https://stedolan.github.io/jq/download/"
                    ;;
                aws)
                    log_info "  - AWS CLI: pip install awscli"
                    ;;
            esac
        done
        return 1
    fi

    log_success "All dependencies are installed"
    return 0
}

validate_config() {
    local config_file=$1

    log_info "Validating configuration file: $config_file"

    # Check if file exists
    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        return 1
    fi

    # Validate JSON syntax
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "Invalid JSON syntax in configuration file"
        return 1
    fi

    # Check required global fields
    local required_global_fields=("backup_base_dir" "log_dir" "s3_endpoint" "s3_region")
    for field in "${required_global_fields[@]}"; do
        if ! jq -e ".global.$field" "$config_file" >/dev/null 2>&1; then
            log_error "Missing required global field: $field"
            return 1
        fi
    done

    # Validate sites array exists
    if ! jq -e '.sites' "$config_file" >/dev/null 2>&1; then
        log_error "Missing 'sites' array in configuration"
        return 1
    fi

    # Check if sites array is empty
    local sites_count=$(jq '.sites | length' "$config_file")
    if [[ $sites_count -eq 0 ]]; then
        log_warning "No sites configured in configuration file"
    fi

    log_success "Configuration validation passed"
    return 0
}

cleanup_temp_files() {
    # Placeholder for any cleanup needed on exit
    if [[ -n "${TEMP_FILES:-}" ]]; then
        rm -f $TEMP_FILES 2>/dev/null || true
    fi
}

################################################################################
# Docker Volume Backup Functions
################################################################################

check_volume_exists() {
    local volume_name=$1

    if docker volume inspect "$volume_name" &>/dev/null; then
        return 0
    else
        return 1
    fi
}

backup_volume() {
    local volume_name=$1
    local site_id=$2
    local site_backup_dir=$3
    local timestamp=$4

    local backup_filename="${site_id}_${volume_name}_${timestamp}.tar.gz"
    local backup_path="$site_backup_dir/$backup_filename"

    log_info "Backing up volume: $volume_name"

    # Check if volume exists
    if ! check_volume_exists "$volume_name"; then
        log_error "Docker volume not found: $volume_name"
        return 1
    fi

    # Dry run mode
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create backup: $backup_filename"
        echo "$backup_path"
        return 0
    fi

    # Create backup using Docker
    if docker run --rm \
        -v "${volume_name}:/source:ro" \
        -v "${site_backup_dir}:/backup" \
        busybox:latest \
        tar czf "/backup/$backup_filename" -C /source . 2>&1 | tee -a "$LOG_FILE"; then

        # Verify backup file was created
        if [[ -f "$backup_path" ]]; then
            local size=$(du -h "$backup_path" | cut -f1)
            log_success "Created backup: $backup_filename ($size)"
            echo "$backup_path"
            return 0
        else
            log_error "Backup file not created: $backup_filename"
            return 1
        fi
    else
        log_error "Failed to create backup for volume: $volume_name"
        return 1
    fi
}

backup_bind_mount() {
    local host_path=$1
    local backup_name=$2
    local site_id=$3
    local site_backup_dir=$4
    local timestamp=$5

    local backup_filename="${site_id}_${backup_name}_${timestamp}.tar.gz"
    local backup_path="$site_backup_dir/$backup_filename"

    log_info "Backing up bind mount: $host_path"

    # Check if host path exists
    if [[ ! -e "$host_path" ]]; then
        log_error "Bind mount path not found: $host_path"
        return 1
    fi

    # Dry run mode
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create backup: $backup_filename"
        echo "$backup_path"
        return 0
    fi

    # Determine if path is a directory or file
    if [[ -d "$host_path" ]]; then
        # Backup directory
        if docker run --rm \
            -v "${host_path}:/source:ro" \
            -v "${site_backup_dir}:/backup" \
            busybox:latest \
            tar czf "/backup/$backup_filename" -C /source . 2>&1 | tee -a "$LOG_FILE"; then

            # Verify backup file was created
            if [[ -f "$backup_path" ]]; then
                local size=$(du -h "$backup_path" | cut -f1)
                log_success "Created backup: $backup_filename ($size)"
                echo "$backup_path"
                return 0
            else
                log_error "Backup file not created: $backup_filename"
                return 1
            fi
        else
            log_error "Failed to create backup for bind mount: $host_path"
            return 1
        fi
    elif [[ -f "$host_path" ]]; then
        # Backup single file
        local parent_dir=$(dirname "$host_path")
        local filename=$(basename "$host_path")

        if docker run --rm \
            -v "${parent_dir}:/source:ro" \
            -v "${site_backup_dir}:/backup" \
            busybox:latest \
            tar czf "/backup/$backup_filename" -C /source "$filename" 2>&1 | tee -a "$LOG_FILE"; then

            # Verify backup file was created
            if [[ -f "$backup_path" ]]; then
                local size=$(du -h "$backup_path" | cut -f1)
                log_success "Created backup: $backup_filename ($size)"
                echo "$backup_path"
                return 0
            else
                log_error "Backup file not created: $backup_filename"
                return 1
            fi
        else
            log_error "Failed to create backup for bind mount file: $host_path"
            return 1
        fi
    else
        log_error "Unknown path type: $host_path"
        return 1
    fi
}

################################################################################
# S3 Operations Functions
################################################################################

upload_to_s3() {
    local local_file=$1
    local s3_bucket=$2
    local s3_path=$3
    local s3_endpoint=$4
    local s3_region=$5

    local filename=$(basename "$local_file")
    local s3_uri="s3://${s3_bucket}/${s3_path}/${filename}"

    log_info "Uploading to S3: $s3_uri"

    # Verify file exists before attempting upload
    if [[ ! -f "$local_file" ]]; then
        log_error "Local file does not exist: $local_file"
        log_error "Cannot upload to S3"
        return 1
    fi

    # Log file details for debugging
    local file_size=$(du -h "$local_file" | cut -f1)
    log_info "Local file verified: $local_file ($file_size)"

    # Dry run mode
    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would upload to: $s3_uri"
        return 0
    fi

    # Retry logic for S3 upload
    local max_retries=3
    local retry=0

    while [[ $retry -lt $max_retries ]]; do
        if aws s3 cp "$local_file" "$s3_uri" \
            --endpoint-url "$s3_endpoint" \
            --region "$s3_region" 2>&1 | tee -a "$LOG_FILE"; then
            log_success "Upload complete: $filename"
            return 0
        fi

        retry=$((retry + 1))
        if [[ $retry -lt $max_retries ]]; then
            log_warning "S3 upload failed (attempt $retry/$max_retries), retrying in 5 seconds..."
            sleep 5
        fi
    done

    log_error "S3 upload failed after $max_retries attempts: $filename"
    return 1
}

list_s3_backups() {
    local s3_bucket=$1
    local s3_path=$2
    local site_id=$3
    local s3_endpoint=$4
    local s3_region=$5

    # List backup packages for this site from S3
    # Packages are named: site_id_package_timestamp.tar.gz
    aws s3 ls "s3://${s3_bucket}/${s3_path}/" \
        --endpoint-url "$s3_endpoint" \
        --region "$s3_region" 2>/dev/null | \
        grep "${site_id}_package_" | \
        awk '{print $4}' || echo ""
}

create_backup_package() {
    local site_id=$1
    local site_backup_dir=$2
    local timestamp=$3
    local volumes_count=$4

    local package_name="${site_id}_package_${timestamp}.tar.gz"
    local package_path="${site_backup_dir}/${package_name}"
    local temp_manifest="${site_backup_dir}/manifest_${timestamp}.txt"

    log_info "Creating backup package: $package_name"

    # Create manifest file
    echo "# Backup Manifest" > "$temp_manifest"
    echo "# Site ID: $site_id" >> "$temp_manifest"
    echo "# Timestamp: $timestamp" >> "$temp_manifest"
    echo "# Date: $(date '+%Y-%m-%d %H:%M:%S')" >> "$temp_manifest"
    echo "# Volumes: $volumes_count" >> "$temp_manifest"
    echo "" >> "$temp_manifest"
    echo "Volumes in this backup:" >> "$temp_manifest"

    # List all volume backup files
    for volume_backup in "$site_backup_dir"/${site_id}_*_${timestamp}.tar.gz; do
        if [[ -f "$volume_backup" ]]; then
            local filename=$(basename "$volume_backup")
            local filesize=$(du -h "$volume_backup" | cut -f1)
            echo "  - $filename ($filesize)" >> "$temp_manifest"
        fi
    done

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would create package: $package_name"
        echo "$package_path"
        return 0
    fi

    # Create package containing all volume backups and manifest
    # Build array of files to include in package
    local files_to_package=()

    # Add all volume backup files for this timestamp
    while IFS= read -r -d '' backup_file; do
        files_to_package+=("$(basename "$backup_file")")
    done < <(find "$site_backup_dir" -name "${site_id}_*_${timestamp}.tar.gz" -print0 2>/dev/null)

    # Add manifest file if it exists
    if [[ -f "$temp_manifest" ]]; then
        files_to_package+=("manifest_${timestamp}.txt")
    fi

    # Check if we have files to package
    if [[ ${#files_to_package[@]} -eq 0 ]]; then
        log_error "No backup files found to create package"
        return 1
    fi

    # Create the tar archive
    local tar_output
    if tar_output=$(tar czf "$package_path" -C "$site_backup_dir" "${files_to_package[@]}" 2>&1); then
        if [[ -f "$package_path" ]]; then
            local package_size=$(du -h "$package_path" | cut -f1)
            log_success "Created backup package: $package_name ($package_size)"
            echo "$package_path"
            return 0
        else
            log_error "Package file not created: $package_name"
            return 1
        fi
    else
        log_error "Failed to create backup package: $package_name"
        log_error "Tar output: $tar_output"
        return 1
    fi
}

delete_from_s3() {
    local s3_bucket=$1
    local s3_path=$2
    local filename=$3
    local s3_endpoint=$4
    local s3_region=$5

    local s3_uri="s3://${s3_bucket}/${s3_path}/${filename}"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would delete from S3: $filename"
        return 0
    fi

    if aws s3 rm "$s3_uri" \
        --endpoint-url "$s3_endpoint" \
        --region "$s3_region" 2>&1 | tee -a "$LOG_FILE"; then
        return 0
    else
        log_error "Failed to delete from S3: $filename"
        return 1
    fi
}

################################################################################
# Retention Management Functions
################################################################################

apply_retention_count() {
    local site_id=$1
    local s3_bucket=$2
    local s3_path=$3
    local keep_count=$4
    local s3_endpoint=$5
    local s3_region=$6

    log_info "Applying count-based retention: keep last $keep_count backups"

    # List S3 backups for this site, sorted by name (which includes timestamp)
    local backups=$(list_s3_backups "$s3_bucket" "$s3_path" "$site_id" "$s3_endpoint" "$s3_region" | sort -r)

    if [[ -z "$backups" ]]; then
        log_info "No backups found in S3 for retention cleanup"
        return 0
    fi

    local count=0
    local deleted=0

    while IFS= read -r backup; do
        [[ -z "$backup" ]] && continue
        count=$((count + 1))

        if [[ $count -gt $keep_count ]]; then
            log_info "Deleting old backup from S3: $backup"
            if delete_from_s3 "$s3_bucket" "$s3_path" "$backup" "$s3_endpoint" "$s3_region"; then
                deleted=$((deleted + 1))
            fi
        fi
    done <<< "$backups"

    if [[ $deleted -gt 0 ]]; then
        log_success "Deleted $deleted old backups from S3"
    else
        log_info "No backups to delete (retention policy satisfied)"
    fi

    return 0
}

apply_retention_days() {
    local site_id=$1
    local s3_bucket=$2
    local s3_path=$3
    local keep_days=$4
    local s3_endpoint=$5
    local s3_region=$6

    log_info "Applying days-based retention: keep backups for $keep_days days"

    # Calculate cutoff timestamp
    local cutoff_date
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        cutoff_date=$(date -v-${keep_days}d +%Y%m%d_%H%M%S)
    else
        # Linux/Git Bash
        cutoff_date=$(date -d "$keep_days days ago" +%Y%m%d_%H%M%S 2>/dev/null || date --date="$keep_days days ago" +%Y%m%d_%H%M%S)
    fi

    log_info "Cutoff date: $cutoff_date"

    # List backups
    local backups=$(list_s3_backups "$s3_bucket" "$s3_path" "$site_id" "$s3_endpoint" "$s3_region")

    if [[ -z "$backups" ]]; then
        log_info "No backups found in S3 for retention cleanup"
        return 0
    fi

    local deleted=0

    while IFS= read -r backup; do
        [[ -z "$backup" ]] && continue

        # Extract timestamp from filename: site_volume_TIMESTAMP.tar.gz
        local timestamp=$(echo "$backup" | grep -oP '\d{8}_\d{6}' | head -n1)

        if [[ -n "$timestamp" && "$timestamp" < "$cutoff_date" ]]; then
            log_info "Deleting old backup from S3: $backup (timestamp: $timestamp)"
            if delete_from_s3 "$s3_bucket" "$s3_path" "$backup" "$s3_endpoint" "$s3_region"; then
                deleted=$((deleted + 1))
            fi
        fi
    done <<< "$backups"

    if [[ $deleted -gt 0 ]]; then
        log_success "Deleted $deleted old backups from S3"
    else
        log_info "No backups to delete (retention policy satisfied)"
    fi

    return 0
}

cleanup_local_backups() {
    local site_backup_dir=$1
    local timestamp=$2

    if [[ "$TEMP_CLEANUP" != "true" ]]; then
        return 0
    fi

    log_info "Cleaning up local backup files..."

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY RUN] Would delete local backups in: $site_backup_dir"
        return 0
    fi

    local deleted_count=0

    # Delete individual volume backup files
    for file in "$site_backup_dir"/*_${timestamp}.tar.gz; do
        if [[ -f "$file" ]]; then
            # Don't delete the package file (contains "_package_")
            if [[ ! "$file" =~ _package_ ]]; then
                rm -f "$file"
                deleted_count=$((deleted_count + 1))
            fi
        fi
    done

    # Delete manifest file
    if [[ -f "$site_backup_dir/manifest_${timestamp}.txt" ]]; then
        rm -f "$site_backup_dir/manifest_${timestamp}.txt"
        deleted_count=$((deleted_count + 1))
    fi

    # Optionally delete the package file after S3 upload
    if [[ -f "$site_backup_dir"/*_package_${timestamp}.tar.gz ]]; then
        for package in "$site_backup_dir"/*_package_${timestamp}.tar.gz; do
            if [[ -f "$package" ]]; then
                rm -f "$package"
                deleted_count=$((deleted_count + 1))
            fi
        done
    fi

    if [[ $deleted_count -gt 0 ]]; then
        log_info "Deleted $deleted_count local backup files"
    fi

    return 0
}

################################################################################
# Main Processing Functions
################################################################################

process_site() {
    local site_index=$1
    local config_file=$2

    # Extract site configuration
    local site_id=$(jq -r ".sites[$site_index].site_id" "$config_file")
    local site_name=$(jq -r ".sites[$site_index].site_name" "$config_file")
    local enabled=$(jq -r ".sites[$site_index].enabled" "$config_file")

    # Check if we should process this site
    if [[ "$enabled" != "true" ]]; then
        log_info "Skipping disabled site: $site_id"
        return 0
    fi

    # If specific site requested, skip others
    if [[ -n "$SPECIFIC_SITE" && "$SPECIFIC_SITE" != "$site_id" ]]; then
        return 0
    fi

    log_info "========================================"
    log_info "Processing site: $site_name ($site_id)"
    log_info "========================================"

    # Create site backup directory
    local site_backup_dir="$BACKUP_BASE_DIR/$site_id"
    mkdir -p "$site_backup_dir"

    # Get timestamp for this backup run
    local timestamp=$(get_timestamp)

    # Get volumes count
    local volumes_count=$(jq ".sites[$site_index].volumes | length" "$config_file")

    if [[ $volumes_count -eq 0 ]]; then
        log_warning "No volumes configured for site: $site_id"
        return 0
    fi

    log_info "Found $volumes_count volume(s) to backup"

    # Backup each volume
    local backup_success=0
    local backup_failed=0
    local backed_up_volumes=()

    for ((v=0; v<volumes_count; v++)); do
        local volume_type=$(jq -r ".sites[$site_index].volumes[$v].type // \"volume\"" "$config_file")
        local volume_name=$(jq -r ".sites[$site_index].volumes[$v].name" "$config_file")
        local volume_desc=$(jq -r ".sites[$site_index].volumes[$v].description" "$config_file")

        log_info "Volume $((v+1))/$volumes_count: $volume_name - $volume_desc (type: $volume_type)"

        # Backup volume based on type
        local backup_file
        if [[ "$volume_type" == "bind" ]]; then
            local bind_path=$(jq -r ".sites[$site_index].volumes[$v].path" "$config_file")
            if backup_file=$(backup_bind_mount "$bind_path" "$volume_name" "$site_id" "$site_backup_dir" "$timestamp"); then
                backup_success=$((backup_success + 1))
                backed_up_volumes+=("$backup_file")
                log_success "Bind mount backup created: $volume_name"
            else
                log_error "Backup failed for bind mount: $volume_name"
                backup_failed=$((backup_failed + 1))
            fi
        else
            # Default to Docker volume
            if backup_file=$(backup_volume "$volume_name" "$site_id" "$site_backup_dir" "$timestamp"); then
                backup_success=$((backup_success + 1))
                backed_up_volumes+=("$backup_file")
                log_success "Volume backup created: $volume_name"
            else
                log_error "Backup failed for volume: $volume_name"
                backup_failed=$((backup_failed + 1))
            fi
        fi
    done

    log_info "Backup summary: $backup_success successful, $backup_failed failed"

    # Only proceed with packaging and upload if at least one volume was backed up
    if [[ $backup_success -eq 0 ]]; then
        log_error "No volumes were successfully backed up for site: $site_id"
        return 1
    fi

    # Create backup package containing all volume backups
    local package_file
    if package_file=$(create_backup_package "$site_id" "$site_backup_dir" "$timestamp" "$volumes_count"); then
        log_success "Backup package created successfully"

        # Verify package file exists before attempting upload
        if [[ ! -f "$package_file" ]]; then
            log_error "Package file does not exist after creation: $package_file"
            log_error "Site backup directory: $site_backup_dir"
            log_error "Listing backup directory contents:"
            ls -lh "$site_backup_dir" | tail -10 | while read line; do log_info "  $line"; done
        else
            # Upload package to S3
            local s3_bucket=$(jq -r ".sites[$site_index].s3.bucket" "$config_file")
            local s3_path=$(jq -r ".sites[$site_index].s3.path" "$config_file")

            if upload_to_s3 "$package_file" "$s3_bucket" "$s3_path" "$S3_ENDPOINT" "$S3_REGION"; then
                log_success "Package uploaded to S3 successfully"
            else
                log_error "Failed to upload package to S3"
            fi
        fi
    else
        log_error "Failed to create backup package"
    fi

    # Apply retention policy
    local retention_type=$(jq -r ".sites[$site_index].retention.type" "$config_file")
    local retention_value=$(jq -r ".sites[$site_index].retention.value" "$config_file")
    local s3_bucket=$(jq -r ".sites[$site_index].s3.bucket" "$config_file")
    local s3_path=$(jq -r ".sites[$site_index].s3.path" "$config_file")

    if [[ "$retention_type" == "count" ]]; then
        apply_retention_count "$site_id" "$s3_bucket" "$s3_path" "$retention_value" "$S3_ENDPOINT" "$S3_REGION"
    elif [[ "$retention_type" == "days" ]]; then
        apply_retention_days "$site_id" "$s3_bucket" "$s3_path" "$retention_value" "$S3_ENDPOINT" "$S3_REGION"
    else
        log_warning "Unknown retention type: $retention_type"
    fi

    # Cleanup local backups if configured
    cleanup_local_backups "$site_backup_dir" "$timestamp"

    log_success "Completed processing site: $site_id"
    echo ""
}

process_all_sites() {
    local config_file=$1

    local sites_count=$(jq '.sites | length' "$config_file")
    log_info "Found $sites_count site(s) in configuration"
    echo ""

    if [[ $sites_count -eq 0 ]]; then
        log_warning "No sites to process"
        return 0
    fi

    local processed=0
    for ((i=0; i<sites_count; i++)); do
        if process_site "$i" "$config_file"; then
            processed=$((processed + 1))
        fi
    done

    return 0
}

################################################################################
# Main Function
################################################################################

main() {
    # Parse command-line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --site)
                SPECIFIC_SITE="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help)
                show_usage
                exit 0
                ;;
            --version)
                echo "Docker Volume Backup Script v${VERSION}"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Load environment variables from .env if it exists
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        # shellcheck disable=SC1091
        source "${SCRIPT_DIR}/.env"
    fi

    # Validate configuration file
    if ! validate_config "$CONFIG_FILE"; then
        exit 1
    fi

    # Load global configuration
    BACKUP_BASE_DIR=$(jq -r '.global.backup_base_dir' "$CONFIG_FILE")
    LOG_DIR=$(jq -r '.global.log_dir' "$CONFIG_FILE")
    S3_ENDPOINT=$(jq -r '.global.s3_endpoint' "$CONFIG_FILE")
    S3_REGION=$(jq -r '.global.s3_region' "$CONFIG_FILE")
    TEMP_CLEANUP=$(jq -r '.global.temp_cleanup // true' "$CONFIG_FILE")

    # Convert relative paths to absolute and normalize
    if [[ ! "$BACKUP_BASE_DIR" = /* ]]; then
        BACKUP_BASE_DIR="$(cd "${SCRIPT_DIR}" && cd "${BACKUP_BASE_DIR}" 2>/dev/null && pwd || echo "${SCRIPT_DIR}/${BACKUP_BASE_DIR}")"
    fi
    # Normalize absolute path to remove ./ and ../
    BACKUP_BASE_DIR="$(realpath -m "$BACKUP_BASE_DIR" 2>/dev/null || readlink -f "$BACKUP_BASE_DIR" 2>/dev/null || echo "$BACKUP_BASE_DIR")"

    if [[ ! "$LOG_DIR" = /* ]]; then
        LOG_DIR="$(cd "${SCRIPT_DIR}" && cd "${LOG_DIR}" 2>/dev/null && pwd || echo "${SCRIPT_DIR}/${LOG_DIR}")"
    fi
    # Normalize absolute path to remove ./ and ../
    LOG_DIR="$(realpath -m "$LOG_DIR" 2>/dev/null || readlink -f "$LOG_DIR" 2>/dev/null || echo "$LOG_DIR")"

    # Setup logging
    setup_logging

    # Log resolved paths for debugging
    log_info "Backup directory: $BACKUP_BASE_DIR"
    log_info "Log directory: $LOG_DIR"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "DRY RUN MODE: No actual changes will be made"
    fi

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Create backup directory
    mkdir -p "$BACKUP_BASE_DIR"

    # Check AWS credentials
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        log_warning "AWS credentials not set in environment"
        log_warning "S3 operations may fail. Please set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
    fi

    # Process sites
    if [[ -n "$SPECIFIC_SITE" ]]; then
        log_info "Processing specific site: $SPECIFIC_SITE"
    fi

    process_all_sites "$CONFIG_FILE"

    log_info "==================================================="
    log_info "Backup process completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "==================================================="
}

# Trap handlers
trap cleanup_temp_files EXIT

# Run main function
main "$@"
