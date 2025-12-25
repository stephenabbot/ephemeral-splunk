#!/bin/bash
# Splunk Enterprise Installer Utility
# This script handles downloading and installing Splunk Enterprise
# Designed to be stored in SSM Parameter Store and executed by user data script

set -euo pipefail

# Configuration
LOG_GROUP="/ec2/ephemeral-splunk"
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
LOG_STREAM="$INSTANCE_ID/splunk-installer.log"

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    
    echo "[$timestamp] [$level] $message"
    
    # Send to CloudWatch Logs
    aws logs put-log-events \
        --log-group-name "$LOG_GROUP" \
        --log-stream-name "$LOG_STREAM" \
        --log-events timestamp=$(date +%s000),message="[$level] $message" \
        --region us-east-1 2>/dev/null || true
}

# Create log stream if it doesn't exist
aws logs create-log-stream \
    --log-group-name "$LOG_GROUP" \
    --log-stream-name "$LOG_STREAM" \
    --region us-east-1 2>/dev/null || true

log_message "INFO" "Starting Splunk Enterprise installation"

# Function to download Splunk
download_splunk() {
    # Method 1: Try direct versioned download
    log_message "INFO" "Attempting direct versioned download"
    local version="9.1.2"
    local build="b6b9c8185839"
    download_url="https://download.splunk.com/products/splunk/releases/${version}/linux/splunk-${version}-${build}-Linux-x86_64.tgz"
    
    if curl -s --head "$download_url" | grep -q "200"; then
        log_message "INFO" "Direct versioned URL valid: $download_url"
        return 0
    fi
    
    # Method 2: Try latest release
    log_message "INFO" "Direct version failed, trying latest release"
    download_url="https://download.splunk.com/products/splunk/releases/latest/linux/splunk-latest-Linux-x86_64.tgz"
    
    if curl -s --head "$download_url" | grep -q "200\|302"; then
        log_message "INFO" "Latest release URL valid: $download_url"
        return 0
    fi
    
    log_message "ERROR" "All download methods failed"
    return 1
}

# Function to install Splunk
install_splunk() {
    local installer_file="$1"
    
    log_message "INFO" "Installing Splunk from $installer_file"
    
    # Extract Splunk
    if ! tar -xzf "$installer_file" -C /opt/; then
        log_message "ERROR" "Failed to extract Splunk installer"
        return 1
    fi
    
    # Create splunk user if needed
    if ! id splunk &>/dev/null; then
        useradd -r -m -d /opt/splunk -s /bin/bash splunk
        log_message "INFO" "Created splunk user"
    fi
    
    # Set ownership
    chown -R splunk:splunk /opt/splunk
    
    # Create user-seed.conf for admin user
    log_message "INFO" "Creating admin user configuration"
    mkdir -p /opt/splunk/etc/system/local
    cat > /opt/splunk/etc/system/local/user-seed.conf << 'EOF'
[user_info]
USERNAME = admin
PASSWORD = changeme
EOF
    chown splunk:splunk /opt/splunk/etc/system/local/user-seed.conf
    
    # Start Splunk
    log_message "INFO" "Starting Splunk for first time"
    if ! sudo -u splunk /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt; then
        log_message "ERROR" "Failed to start Splunk"
        return 1
    fi
    
    # Enable boot start
    /opt/splunk/bin/splunk enable boot-start -user splunk --accept-license --answer-yes
    
    # Basic configuration
    sudo -u splunk /opt/splunk/bin/splunk http-event-collector enable -auth admin:changeme
    sudo -u splunk /opt/splunk/bin/splunk add index test_data -auth admin:changeme
    
    log_message "INFO" "Splunk installation completed successfully"
    return 0
}

# Main execution
main() {
    cd /tmp
    
    # Get download URL
    if ! download_splunk; then
        log_message "ERROR" "Failed to determine download URL"
        exit 1
    fi
    
    # Download installer
    log_message "INFO" "Downloading Splunk installer from: $download_url"
    if ! wget -O splunk-installer.tgz "$download_url"; then
        log_message "ERROR" "Failed to download Splunk installer"
        exit 1
    fi
    
    # Verify download
    if [ ! -f splunk-installer.tgz ] || [ ! -s splunk-installer.tgz ]; then
        log_message "ERROR" "Downloaded file is missing or empty"
        exit 1
    fi
    
    # Check if it's actually a tar.gz file
    if ! file splunk-installer.tgz | grep -q "gzip compressed"; then
        log_message "ERROR" "Downloaded file is not a valid gzip archive"
        head -c 500 splunk-installer.tgz | log_message "ERROR" "File content preview: $(cat)"
        exit 1
    fi
    
    log_message "INFO" "Download successful, file size: $(wc -c < splunk-installer.tgz) bytes"
    
    # Install Splunk
    if ! install_splunk splunk-installer.tgz; then
        log_message "ERROR" "Splunk installation failed"
        exit 1
    fi
    
    # Verify installation
    if pgrep -f "splunkd" > /dev/null; then
        log_message "INFO" "SUCCESS: Splunk is running"
        echo "SPLUNK_INSTALLATION_COMPLETE" > /tmp/splunk-install-status
    else
        log_message "ERROR" "Splunk is not running after installation"
        exit 1
    fi
    
    # Cleanup
    rm -f splunk-installer.tgz
    
    log_message "INFO" "Splunk installation process completed"
}

# Execute main function
main "$@"
