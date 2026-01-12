# Docker Volume Backup System

A centralized backup solution for Docker volumes with S3 upload support and configurable retention policies.

## Features

- Automated Docker volume backups to compressed tar.gz archives
- **Package all volumes for a site together** into a single archive for easy management
- Upload backup packages to Wasabi S3-compatible storage
- Configurable retention policies (count-based or days-based) per site
- Support for multiple sites/projects in a single configuration
- Automatic manifest file generation listing all volumes in the backup
- Comprehensive logging with timestamps
- Dry-run mode for testing
- Retry logic for S3 uploads
- Optional local backup cleanup after S3 upload

## Prerequisites

Before using this backup system, ensure you have the following installed:

- **Docker**: Version 19.03 or higher
  - Install from: https://docs.docker.com/get-docker/
- **jq**: JSON processor for parsing configuration files
  - Linux: `apt-get install jq` or `yum install jq`
  - macOS: `brew install jq`
  - Windows: Download from https://stedolan.github.io/jq/download/
- **AWS CLI**: For S3 uploads to Wasabi
  - Install: `pip install awscli`
  - Or follow: https://aws.amazon.com/cli/
- **Bash**: Version 4.0 or higher
  - Linux/macOS: Pre-installed
  - Windows: Use Git Bash or WSL

## Installation

1. **Clone or download this repository**

```bash
cd /opt
git clone <repository-url> docker-backups
cd docker-backups
```

2. **Make the backup script executable**

```bash
chmod +x backup.sh
```

3. **Create your configuration file**

```bash
cp config.example.json config.json
```

4. **Set up AWS credentials for Wasabi**

```bash
cp .env.example .env
```

Edit `.env` and add your Wasabi credentials:

```bash
AWS_ACCESS_KEY_ID=your_wasabi_access_key
AWS_SECRET_ACCESS_KEY=your_wasabi_secret_key
AWS_DEFAULT_REGION=us-east-1
```

**Important**: Never commit `.env` to version control!

5. **Edit the configuration file**

Edit `config.json` to define your sites, volumes, and retention policies (see Configuration section below).

## Configuration

### Configuration File Structure

The `config.json` file consists of two main sections:

#### Global Settings

```json
{
  "global": {
    "backup_base_dir": "./backups",
    "log_dir": "./logs",
    "s3_endpoint": "https://s3.wasabisys.com",
    "s3_region": "us-east-1",
    "temp_cleanup": true
  }
}
```

- `backup_base_dir`: Local directory for storing backups (relative or absolute path)
- `log_dir`: Directory for log files
- `s3_endpoint`: Wasabi S3 endpoint URL
- `s3_region`: AWS region for Wasabi (typically `us-east-1`, `us-east-2`, `us-west-1`, or `eu-central-1`)
- `temp_cleanup`: Whether to delete local backups after successful S3 upload (`true`/`false`)

#### Wasabi Regions and Endpoints

| Region | Endpoint URL |
|--------|-------------|
| US East 1 (N. Virginia) | https://s3.wasabisys.com |
| US East 2 (N. Virginia) | https://s3.us-east-2.wasabisys.com |
| US West 1 (Oregon) | https://s3.us-west-1.wasabisys.com |
| EU Central 1 (Amsterdam) | https://s3.eu-central-1.wasabisys.com |

#### Site Configuration

Each site represents a project or application with one or more Docker volumes to backup.

```json
{
  "sites": [
    {
      "site_id": "wordpress-prod",
      "site_name": "WordPress Production",
      "enabled": true,
      "backup_frequency": "daily",
      "retention": {
        "type": "count",
        "value": 7,
        "description": "Keep last 7 backups"
      },
      "s3": {
        "bucket": "my-backups",
        "path": "docker-volumes/wordpress-prod"
      },
      "volumes": [
        {
          "name": "wordpress_data",
          "description": "WordPress uploads and content"
        },
        {
          "name": "wordpress_db",
          "description": "MySQL database volume"
        }
      ]
    }
  ]
}
```

**Field Descriptions:**

- `site_id`: Unique identifier (used in backup filenames and directories)
- `site_name`: Human-readable name for the site
- `enabled`: Set to `false` to skip this site during backups
- `backup_frequency`: Documentation only (e.g., "daily", "weekly", "hourly")
- `retention.type`: Either `"count"` or `"days"`
  - `count`: Keep the last N backups
  - `days`: Keep backups for N days
- `retention.value`: Number of backups to keep (for count) or days to retain (for days)
- `s3.bucket`: Wasabi S3 bucket name
- `s3.path`: Path within the bucket for this site's backups
- `volumes`: Array of Docker volumes to backup
  - `name`: Docker volume name (must exist)
  - `description`: Description for logging

### Retention Policy Examples

**Keep Last 7 Backups:**
```json
"retention": {
  "type": "count",
  "value": 7
}
```

**Keep Backups for 30 Days:**
```json
"retention": {
  "type": "days",
  "value": 30
}
```

## Usage

### Basic Usage

Backup all enabled sites:

```bash
./backup.sh
```

### Command-Line Options

```bash
./backup.sh [OPTIONS]

OPTIONS:
  --config FILE       Path to configuration file (default: ./config.json)
  --site SITE_ID      Backup only specific site by site_id
  --dry-run           Show what would be done without executing
  --help              Display help message
  --version           Show version information
```

### Examples

**Backup all sites:**
```bash
./backup.sh
```

**Backup specific site:**
```bash
./backup.sh --site wordpress-prod
```

**Use custom configuration:**
```bash
./backup.sh --config /etc/backup/config.json
```

**Dry run (test without executing):**
```bash
./backup.sh --dry-run
```

**Backup specific site with dry run:**
```bash
./backup.sh --site wordpress-prod --dry-run
```

### Scheduling Backups

While this script is designed for manual execution, you can schedule it using:

**Cron (Linux/macOS):**

```bash
# Edit crontab
crontab -e

# Add line to run daily at 2 AM
0 2 * * * /opt/docker-backups/backup.sh >> /var/log/docker-backup-cron.log 2>&1

# Weekly on Sundays at 3 AM
0 3 * * 0 /opt/docker-backups/backup.sh

# Every 6 hours
0 */6 * * * /opt/docker-backups/backup.sh
```

**Windows Task Scheduler:**

Create a scheduled task to run the script via Git Bash or WSL.

## Backup File Naming and Structure

### Backup Package Format

All volumes for a site are packaged together into a single compressed archive:

```
{site_id}_package_{timestamp}.tar.gz
```

Example: `wordpress-prod_package_20251219_143015.tar.gz`

- `wordpress-prod`: Site ID
- `package`: Indicates this is a complete site backup package
- `20251219_143015`: Timestamp (YYYYMMDD_HHMMSS)

### Package Contents

Each backup package contains:

1. **Individual volume backups**: `{site_id}_{volume_name}_{timestamp}.tar.gz`
   - Example: `wordpress-prod_wordpress_data_20251219_143015.tar.gz`
   - Example: `wordpress-prod_wordpress_db_20251219_143015.tar.gz`

2. **Manifest file**: `manifest_{timestamp}.txt`
   - Lists all volumes included in the backup
   - Contains backup metadata (site ID, timestamp, volume count)
   - Shows file sizes for each volume backup

### Example Package Structure

When you extract `wordpress-prod_package_20251219_143015.tar.gz`, you get:

```
wordpress-prod_wordpress_data_20251219_143015.tar.gz
wordpress-prod_wordpress_db_20251219_143015.tar.gz
manifest_20251219_143015.txt
```

## Logs

Log files are created in the configured `log_dir` with the format:

```
backup_YYYYMMDD_HHMMSS.log
```

Each log entry includes:
- Timestamp
- Log level (INFO, SUCCESS, ERROR, WARNING)
- Message

Example log output:

```
[2025-12-19 14:30:15] [INFO] Docker Volume Backup Script v1.1.0
[2025-12-19 14:30:15] [INFO] Processing site: WordPress Production (wordpress-prod)
[2025-12-19 14:30:16] [INFO] Backing up volume: wordpress_data
[2025-12-19 14:30:45] [SUCCESS] Created backup: wordpress-prod_wordpress_data_20251219_143015.tar.gz (245M)
[2025-12-19 14:30:46] [INFO] Backing up volume: wordpress_db
[2025-12-19 14:31:15] [SUCCESS] Created backup: wordpress-prod_wordpress_db_20251219_143015.tar.gz (512M)
[2025-12-19 14:31:16] [INFO] Creating backup package: wordpress-prod_package_20251219_143015.tar.gz
[2025-12-19 14:31:45] [SUCCESS] Created backup package: wordpress-prod_package_20251219_143015.tar.gz (750M)
[2025-12-19 14:32:30] [SUCCESS] Package uploaded to S3 successfully
[2025-12-19 14:32:31] [INFO] Applying count-based retention: keep last 7 backups
```

## Restoring from Backup

### Step 1: Download Backup Package from S3

```bash
# List available backup packages
aws s3 ls s3://my-backups/docker-volumes/wordpress-prod/ \
  --endpoint-url https://s3.wasabisys.com

# Download specific backup package
aws s3 cp s3://my-backups/docker-volumes/wordpress-prod/wordpress-prod_package_20251219_143015.tar.gz ./ \
  --endpoint-url https://s3.wasabisys.com
```

### Step 2: Extract the Backup Package

```bash
# Extract the backup package to get individual volume backups
mkdir -p restore_temp
tar xzf wordpress-prod_package_20251219_143015.tar.gz -C restore_temp/

# View the manifest to see what's included
cat restore_temp/manifest_20251219_143015.txt
```

### Step 3: Restore Individual Volumes

```bash
cd restore_temp/

# Restore first volume (e.g., wordpress_data)
docker volume create wordpress_data_restored
docker run --rm \
  -v wordpress_data_restored:/target \
  -v $(pwd):/backup \
  alpine:latest \
  tar xzf /backup/wordpress-prod_wordpress_data_20251219_143015.tar.gz -C /target

# Restore second volume (e.g., wordpress_db)
docker volume create wordpress_db_restored
docker run --rm \
  -v wordpress_db_restored:/target \
  -v $(pwd):/backup \
  alpine:latest \
  tar xzf /backup/wordpress-prod_wordpress_db_20251219_143015.tar.gz -C /target

# Verify contents
docker run --rm -v wordpress_data_restored:/data alpine ls -la /data
docker run --rm -v wordpress_db_restored:/data alpine ls -la /data
```

### Step 4: Restore to Original Volume Names (if needed)

```bash
# Stop containers using the volumes first
docker-compose down

# Remove old volumes
docker volume rm wordpress_data wordpress_db

# Create new volumes with original names
docker volume create wordpress_data
docker volume create wordpress_db

# Restore from backup
docker run --rm \
  -v wordpress_data:/target \
  -v $(pwd):/backup \
  alpine:latest \
  tar xzf /backup/wordpress-prod_wordpress_data_20251219_143015.tar.gz -C /target

docker run --rm \
  -v wordpress_db:/target \
  -v $(pwd):/backup \
  alpine:latest \
  tar xzf /backup/wordpress-prod_wordpress_db_20251219_143015.tar.gz -C /target

# Restart containers
docker-compose up -d
```

### Quick Restore Script

For convenience, here's a script to automate the restoration process:

```bash
#!/bin/bash
# restore.sh - Restore all volumes from a backup package

PACKAGE_FILE="$1"
RESTORE_DIR="restore_temp_$(date +%s)"

if [[ -z "$PACKAGE_FILE" ]]; then
    echo "Usage: $0 <package_file.tar.gz>"
    exit 1
fi

# Extract package
mkdir -p "$RESTORE_DIR"
tar xzf "$PACKAGE_FILE" -C "$RESTORE_DIR/"
cd "$RESTORE_DIR"

# Show manifest
echo "=== Backup Contents ==="
cat manifest_*.txt
echo ""

# Restore each volume backup
for volume_backup in *_*.tar.gz; do
    # Skip if it's the package itself
    [[ "$volume_backup" == *"_package_"* ]] && continue

    # Extract volume name from filename (remove site_id and timestamp)
    volume_name=$(echo "$volume_backup" | sed -E 's/^[^_]+_([^_]+)_[0-9_]+\.tar\.gz$/\1/')

    echo "Restoring volume: $volume_name"

    # Create volume
    docker volume create "${volume_name}_restored" 2>/dev/null || true

    # Restore data
    docker run --rm \
        -v "${volume_name}_restored:/target" \
        -v "$(pwd):/backup" \
        alpine:latest \
        tar xzf "/backup/$volume_backup" -C /target

    echo "✓ Restored: $volume_name -> ${volume_name}_restored"
done

echo ""
echo "Restoration complete! Volumes created with '_restored' suffix."
echo "Verify the data, then rename volumes as needed."
```

### Important Notes on Restoration

- **Always test restores in a non-production environment first**
- Stop all containers using the volumes before restoration
- The backup package contains all volumes for the site in one file
- Check the manifest file to see exactly what's included in the backup
- Verify file permissions and ownership after restoration
- For database volumes, ensure database is stopped before restore
- Consider restoring to new volume names first (with `_restored` suffix) to test before replacing production volumes

## Wasabi S3 Setup

### 1. Create a Wasabi Account

Sign up at: https://wasabi.com/

### 2. Create an S3 Bucket

1. Log in to Wasabi Console
2. Navigate to "Buckets"
3. Click "Create Bucket"
4. Choose a unique bucket name (e.g., `my-backups`)
5. Select a region
6. Create the bucket

### 3. Generate Access Keys

1. Go to "Access Keys" in Wasabi Console
2. Click "Create New Access Key"
3. Save both the Access Key ID and Secret Access Key
4. Add them to your `.env` file

### 4. Configure AWS CLI

The script automatically uses the endpoint URL from your configuration. No additional AWS CLI configuration is needed beyond setting environment variables in `.env`.

To test AWS CLI connection:

```bash
# Load environment variables
source .env

# List buckets
aws s3 ls --endpoint-url https://s3.wasabisys.com

# Test upload
echo "test" > test.txt
aws s3 cp test.txt s3://my-backups/test/ --endpoint-url https://s3.wasabisys.com

# Test download
aws s3 cp s3://my-backups/test/test.txt ./test-download.txt --endpoint-url https://s3.wasabisys.com

# Cleanup
rm test.txt test-download.txt
aws s3 rm s3://my-backups/test/test.txt --endpoint-url https://s3.wasabisys.com
```

## Troubleshooting

### Common Issues

**1. "Docker volume not found" error**

- Verify the volume exists: `docker volume ls`
- Check the volume name in your configuration matches exactly
- Ensure the volume name doesn't have typos

**2. S3 upload fails**

- Check AWS credentials in `.env`
- Verify S3 endpoint URL matches your Wasabi region
- Test AWS CLI connection (see Wasabi Setup section)
- Check network connectivity
- Verify bucket name and permissions

**3. "jq: command not found"**

Install jq:
- Linux: `apt-get install jq` or `yum install jq`
- macOS: `brew install jq`
- Windows: Download from https://stedolan.github.io/jq/

**4. Permission denied errors**

- Ensure script is executable: `chmod +x backup.sh`
- Check Docker socket permissions: `ls -la /var/run/docker.sock`
- Add user to docker group: `sudo usermod -aG docker $USER`

**5. Backups are very large**

- Docker volumes include all data, which can be large for databases
- Consider excluding certain volumes from backups
- Use database-specific backup tools for databases (mysqldump, pg_dump)
- Enable `temp_cleanup: true` to save local disk space

**6. Date command errors on macOS/Windows**

The script includes compatibility for both GNU date (Linux) and BSD date (macOS). If you encounter date-related errors:
- Ensure you're using Bash 4.0+
- On Windows, use Git Bash or WSL
- The script automatically detects the OS and uses appropriate date commands

### Enable Debug Mode

For detailed debugging, run with bash -x:

```bash
bash -x backup.sh
```

This will print each command as it executes.

### Check Logs

All operations are logged. Check the latest log file:

```bash
ls -lt logs/
tail -f logs/backup_YYYYMMDD_HHMMSS.log
```

## Security Considerations

1. **Credentials Protection**
   - Never commit `.env` to version control
   - Set restrictive permissions: `chmod 600 .env`
   - Rotate access keys regularly
   - Use separate credentials for backups (limited permissions)

2. **File Permissions**
   - Script: `chmod 700 backup.sh`
   - Config: `chmod 600 config.json` (if it contains sensitive info)
   - Logs may contain volume names and paths

3. **Backup Encryption**
   - Wasabi supports server-side encryption
   - For additional security, consider encrypting backups before upload:

```bash
# Encrypt backup
openssl enc -aes-256-cbc -salt -in backup.tar.gz -out backup.tar.gz.enc -k your-password

# Decrypt for restore
openssl enc -aes-256-cbc -d -in backup.tar.gz.enc -out backup.tar.gz -k your-password
```

4. **Network Security**
   - All S3 transfers use HTTPS
   - Wasabi provides encryption in transit and at rest
   - Use VPN if backing up sensitive data over untrusted networks

## Performance Tips

1. **Large Volumes**
   - Backups of large volumes (>10GB) can take significant time
   - Consider scheduling backups during off-peak hours
   - Monitor disk space on both local and S3

2. **Parallel Backups**
   - Current implementation processes sites sequentially
   - For faster backups, run multiple instances with `--site` flag:

```bash
./backup.sh --site wordpress-prod &
./backup.sh --site nextcloud-prod &
wait
```

3. **Compression**
   - The script uses gzip compression (tar czf)
   - For better compression, modify to use pigz (parallel gzip):

```bash
# Install pigz
apt-get install pigz

# Modify backup command in script
tar -I pigz -cf backup.tar.gz ...
```

## Maintenance

### Regular Tasks

1. **Monitor Logs**
   - Review logs for errors
   - Set up log rotation for the logs directory

2. **Test Restores**
   - Periodically test backup restoration
   - Verify backups are not corrupted

3. **Review Retention Policies**
   - Ensure retention policies match your needs
   - Balance storage costs with recovery requirements

4. **Update Dependencies**
   - Keep Docker, AWS CLI, and jq updated
   - Test script after updates

### Log Rotation

Create a logrotate configuration:

```bash
# /etc/logrotate.d/docker-backup
/opt/docker-backups/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    missingok
}
```

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test thoroughly
4. Submit a pull request

## License

MIT License - See LICENSE file for details

## Support

For issues, questions, or suggestions:
- Open an issue on GitHub
- Check existing issues for solutions
- Review logs for error details

## Changelog

### Version 1.1.0 (2025-12-19)
- **New Feature**: Package all volumes for a site together into a single archive
- Automatic manifest file generation listing all volumes in backup
- Updated backup naming: `{site_id}_package_{timestamp}.tar.gz`
- Improved restoration workflow with package extraction
- Updated retention policies to work with backup packages
- Enhanced documentation with detailed restoration guide

### Version 1.0.0 (2025-12-19)
- Initial release
- Docker volume backup support
- S3 upload with Wasabi support
- Count-based and days-based retention policies
- Comprehensive logging
- Dry-run mode
- Retry logic for S3 uploads
