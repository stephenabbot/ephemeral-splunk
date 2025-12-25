#!/bin/bash
# scripts/deploy.sh - Deploy ephemeral Splunk infrastructure

set -euo pipefail

# Change to project root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

# Load environment variables
if [ -f ".env" ]; then
    set -a
    source .env
    set +a
fi

# Disable AWS CLI pager
export AWS_PAGER=""

echo "🚀 DEPLOYING EPHEMERAL SPLUNK INFRASTRUCTURE 🚀"
echo ""
echo "This will deploy a fresh Splunk Enterprise instance with monitoring and cost controls"
echo ""

# Verify prerequisites
echo "Step 1: Verifying prerequisites..."
./scripts/verify-prerequisites.sh || exit 1

# Step 2: Check for project deployment role and assume if available
echo ""
echo "Step 2: Checking for project deployment role..."

# Extract project name from git remote URL
PROJECT_NAME=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/][^/]+/([^/.]+)(\.git)?$|\1|' || echo "")

if [ -z "$PROJECT_NAME" ]; then
  echo "⚠️  Could not determine project name from git remote"
  echo "  Using current credentials"
else
  echo "  Project name: $PROJECT_NAME"

  # Look up project-specific deployment role
  PROJECT_ROLE_ARN=$(aws ssm get-parameter --region us-east-1 --name "/deployment-roles/${PROJECT_NAME}/role-arn" --query Parameter.Value --output text 2>/dev/null || echo "")

  if [ -n "$PROJECT_ROLE_ARN" ]; then
    echo "✓ Project deployment role found: $PROJECT_ROLE_ARN"
    echo "  Attempting to assume role for deployment..."

    if TEMP_CREDS=$(aws sts assume-role --role-arn "$PROJECT_ROLE_ARN" --role-session-name "${PROJECT_NAME}-deploy-$(date +%s)" --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>/dev/null); then
      export AWS_ACCESS_KEY_ID=$(echo "$TEMP_CREDS" | cut -f1)
      export AWS_SECRET_ACCESS_KEY=$(echo "$TEMP_CREDS" | cut -f2)
      export AWS_SESSION_TOKEN=$(echo "$TEMP_CREDS" | cut -f3)
      echo "✓ Successfully assumed project deployment role"
    else
      echo "⚠️  Failed to assume project role, using current credentials"
      echo "  This is normal for local development with admin credentials"
    fi
  else
    echo "ℹ️  Project deployment role not found at /deployment-roles/${PROJECT_NAME}/role-arn"
    echo "  Using current credentials"
    echo "  To create a deployment role, run terraform-aws-deployment-roles"
  fi
fi

# Step 3: Configure OpenTofu backend
echo ""
echo "Step 3: Configuring OpenTofu backend..."

# Get backend configuration from foundation
STATE_BUCKET=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/s3-state-bucket" --query Parameter.Value --output text 2>/dev/null || echo "")
DYNAMODB_TABLE=$(aws ssm get-parameter --region us-east-1 --name "/terraform/foundation/dynamodb-lock-table" --query Parameter.Value --output text 2>/dev/null || echo "")

if [ -z "$STATE_BUCKET" ] || [ -z "$DYNAMODB_TABLE" ]; then
  echo "❌ Foundation backend configuration not found"
  echo "  Deploy terraform-aws-cfn-foundation first"
  exit 1
fi

# Get GitHub repository info for state key
GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github\.com[:/]\([^/]*\/[^/.]*\).*/\1/' || echo "unknown/unknown")
BACKEND_KEY="ephemeral-splunk/$(echo "$GITHUB_REPO" | tr '/' '-')/terraform.tfstate"

echo "✓ Backend configuration:"
echo "  Bucket: $STATE_BUCKET"
echo "  DynamoDB: $DYNAMODB_TABLE"
echo "  Key: $BACKEND_KEY"

# Step 4: Initialize OpenTofu
echo ""
echo "Step 4: Initializing OpenTofu..."

# Clear any stale DynamoDB locks before initialization
aws dynamodb scan --table-name "$DYNAMODB_TABLE" --filter-expression "contains(LockID, :key)" --expression-attribute-values "{\":key\":{\"S\":\"$BACKEND_KEY\"}}" --query 'Items[].LockID.S' --output text 2>/dev/null | tr '\t' '\n' | while read -r lock_id; do
  if [ -n "$lock_id" ]; then
    echo "Clearing stale lock: $lock_id"
    aws dynamodb delete-item --table-name "$DYNAMODB_TABLE" --key "{\"LockID\":{\"S\":\"$lock_id\"}}" 2>/dev/null || true
  fi
done

tofu init -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="dynamodb_table=$DYNAMODB_TABLE" \
    -backend-config="key=$BACKEND_KEY" \
    -backend-config="region=us-east-1"

# Step 5: Plan deployment
echo ""
echo "Step 5: Planning deployment..."
tofu plan -out=tfplan \
    -var="aws_region=${AWS_REGION:-us-east-1}" \
    -var="deployment_environment=${DEPLOYMENT_ENVIRONMENT:-prd}" \
    -var="tag_owner=${TAG_OWNER:-Platform Team}" \
    -var="ec2_instance_type=${EC2_INSTANCE_TYPE:-t3.large}" \
    -var="ebs_volume_size=${EBS_VOLUME_SIZE:-100}" \
    -var="cost_alarm_email=${COST_ALARM_EMAIL:-abbotnh@yahoo.com}"

# Step 6: Apply deployment
echo ""
echo "Step 6: Applying deployment..."
tofu apply tfplan

# Step 7: Generate outputs and store in SSM
echo ""
echo "Step 7: Generating outputs and storing in SSM..."

# Generate outputs JSON (this will be gitignored)
tofu output -json > infrastructure-outputs.json

# Store outputs in SSM for consuming projects
if [ -f infrastructure-outputs.json ]; then
  INSTANCE_ID=$(jq -r '.instance_info.value.instance_id' infrastructure-outputs.json)
  INSTANCE_IP=$(jq -r '.instance_info.value.instance_ip' infrastructure-outputs.json)
  LOG_GROUP=$(jq -r '.instance_info.value.log_group_name' infrastructure-outputs.json)
  
  echo "Storing SSM parameters for ephemeral-splunk..."
  
  aws ssm put-parameter --region us-east-1 --name "/ephemeral-splunk/instance-id" --value "$INSTANCE_ID" --type String --overwrite > /dev/null
  aws ssm put-parameter --region us-east-1 --name "/ephemeral-splunk/instance-ip" --value "$INSTANCE_IP" --type String --overwrite > /dev/null
  aws ssm put-parameter --region us-east-1 --name "/ephemeral-splunk/log-group" --value "$LOG_GROUP" --type String --overwrite > /dev/null
fi

echo ""
echo "✅ DEPLOYMENT COMPLETE"
echo ""
echo "📋 Summary:"
echo "  • Ephemeral Splunk infrastructure deployed successfully"
echo "  • Instance ID: $(jq -r '.instance_info.value.instance_id' infrastructure-outputs.json)"
echo "  • Public IP: $(jq -r '.instance_info.value.instance_ip' infrastructure-outputs.json)"
echo "  • CloudWatch Logs: $(jq -r '.instance_info.value.log_group_name' infrastructure-outputs.json)"
echo ""
echo "🔍 Next steps:"
echo "  1. Wait 5-10 minutes for Splunk installation to complete"
echo "  2. Check installation status: ./scripts/verify-installation.sh"
echo "  3. Connect via SSM: $(jq -r '.connection_info.value.ssm_command' infrastructure-outputs.json)"
echo "  4. Access Splunk UI: $(jq -r '.connection_info.value.port_forward_command' infrastructure-outputs.json)"
echo "  5. Open browser to: $(jq -r '.connection_info.value.splunk_url' infrastructure-outputs.json)"
echo "  6. Default login: admin / changeme"
echo ""
echo "💰 Cost monitoring:"
echo "  • Cost alarms configured for \$5, \$10, \$20"
echo "  • Email notifications sent to: ${COST_ALARM_EMAIL:-abbotnh@yahoo.com}"
echo ""
echo "🚀 Ephemeral Splunk is ready for use! 🚀"
