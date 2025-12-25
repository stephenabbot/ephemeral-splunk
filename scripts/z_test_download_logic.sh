#!/bin/bash
# Local test version of the Splunk installer utility
# Tests download logic without AWS dependencies

set -euo pipefail

# Mock logging function for local testing
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
    echo "[$timestamp] [$level] $message"
}

# Function to download Splunk (same as utility script)
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

# Test download logic
main() {
    log_message "INFO" "Testing Splunk download logic locally"
    
    # Get download URL
    if ! download_splunk; then
        log_message "ERROR" "Failed to determine download URL"
        exit 1
    fi
    
    log_message "INFO" "Testing partial download from: $download_url"
    
    # Test partial download (first 1MB)
    if curl -s --range 0-1048576 "$download_url" -o /tmp/splunk_test.partial; then
        log_message "INFO" "Partial download successful"
        log_message "INFO" "Downloaded $(wc -c < /tmp/splunk_test.partial) bytes"
        
        # Verify it's a valid gzip file
        if file /tmp/splunk_test.partial | grep -q "gzip compressed"; then
            log_message "INFO" "SUCCESS: File is valid gzip archive"
        else
            log_message "ERROR" "File is not a valid gzip archive"
            log_message "ERROR" "File type: $(file /tmp/splunk_test.partial)"
        fi
        
        rm -f /tmp/splunk_test.partial
    else
        log_message "ERROR" "Partial download failed"
        exit 1
    fi
    
    log_message "INFO" "Download logic test completed successfully"
}

main "$@"
