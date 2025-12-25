#!/bin/bash
# Test script to verify Splunk download logic before deployment
set -euo pipefail

echo "=== Testing Splunk Download Logic ==="

# Use Splunk's direct download API instead of scraping HTML
echo "1. Using Splunk's official download approach..."

# Splunk provides a more reliable way to get download URLs
# Use their release API or direct download pattern
SPLUNK_VERSION="9.1.2"
SPLUNK_BUILD="b6b9c8185839"
DIRECT_URL="https://download.splunk.com/products/splunk/releases/${SPLUNK_VERSION}/linux/splunk-${SPLUNK_VERSION}-${SPLUNK_BUILD}-Linux-x86_64.tgz"

echo "Testing direct download URL: $DIRECT_URL"

# Test if direct URL works
if curl -s --head "$DIRECT_URL" | grep -q "200 OK"; then
  echo "SUCCESS: Direct URL is valid"
  
  echo "2. Testing partial download..."
  if curl -s --range 0-1048576 "$DIRECT_URL" -o /tmp/splunk_test_direct.partial; then
    echo "SUCCESS: Direct download test successful"
    echo "Downloaded $(wc -c < /tmp/splunk_test_direct.partial) bytes"
    file /tmp/splunk_test_direct.partial
    rm -f /tmp/splunk_test_direct.partial
  fi
else
  echo "Direct URL failed, trying alternative approach..."
  
  # Alternative: Use Splunk's latest release redirect
  LATEST_URL="https://download.splunk.com/products/splunk/releases/latest/linux/splunk-latest-Linux-x86_64.tgz"
  
  echo "3. Testing latest release URL: $LATEST_URL"
  if curl -s --head "$LATEST_URL" | grep -q "200\|302"; then
    echo "SUCCESS: Latest URL is valid"
    
    # Get the actual redirect URL
    ACTUAL_URL=$(curl -s -I "$LATEST_URL" | grep -i location | cut -d' ' -f2 | tr -d '\r')
    echo "Redirects to: $ACTUAL_URL"
    
    if [ -n "$ACTUAL_URL" ]; then
      echo "4. Testing redirected download..."
      if curl -s --range 0-1048576 "$ACTUAL_URL" -o /tmp/splunk_test_latest.partial; then
        echo "SUCCESS: Latest download test successful"
        echo "Downloaded $(wc -c < /tmp/splunk_test_latest.partial) bytes"
        file /tmp/splunk_test_latest.partial
        rm -f /tmp/splunk_test_latest.partial
      fi
    fi
  else
    echo "ERROR: Both direct and latest URLs failed"
    echo "Will need to implement HTML parsing fallback"
  fi
fi

echo "=== SSM Connectivity Test ==="

# Test SSM connectivity requirements
echo "5. Checking SSM connectivity requirements..."

# Check if we can reach SSM endpoints
SSM_ENDPOINTS=(
  "ssm.us-east-1.amazonaws.com"
  "ssmmessages.us-east-1.amazonaws.com" 
  "ec2messages.us-east-1.amazonaws.com"
)

for endpoint in "${SSM_ENDPOINTS[@]}"; do
  echo "Testing connectivity to $endpoint..."
  if curl -s --connect-timeout 5 --max-time 10 "https://$endpoint" > /dev/null 2>&1; then
    echo "SUCCESS: Can reach $endpoint"
  else
    echo "WARNING: Cannot reach $endpoint (may be normal from local machine)"
  fi
done

echo "=== Test Complete ==="
