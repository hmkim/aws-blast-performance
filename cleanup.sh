#!/bin/bash
set -e

PROJECT_NAME="${PROJECT_NAME:-blast-perf-test}"
REGION="${REGION:-us-east-1}"

echo "=========================================="
echo "BLAST Performance Test Infrastructure Cleanup"
echo "=========================================="

read -p "Delete all resources? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Clean up S3 buckets
echo -e "\n[1/5] Cleaning up S3 buckets..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
QUERY_BUCKET="${PROJECT_NAME}-queries-${ACCOUNT_ID}"
LUSTRE_BUCKET="blast-nt-lustre-${REGION}-${ACCOUNT_ID}"

echo "Deleting query bucket: $QUERY_BUCKET"
aws s3 rb s3://$QUERY_BUCKET --force --region $REGION 2>/dev/null || echo "Bucket does not exist"

echo "Deleting Lustre bucket: $LUSTRE_BUCKET"
aws s3 rb s3://$LUSTRE_BUCKET --force --region $REGION 2>/dev/null || echo "Bucket does not exist"

# Delete Batch environment
echo -e "\n[2/5] Deleting AWS Batch environment..."
aws cloudformation delete-stack \
  --stack-name ${PROJECT_NAME}-batch \
  --region $REGION 2>/dev/null || echo "Stack does not exist"

echo "Waiting for Batch stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name ${PROJECT_NAME}-batch \
  --region $REGION 2>/dev/null || true
echo "✓ Batch environment deleted"

# Delete Lustre
echo -e "\n[3/5] Deleting Lustre storage..."
aws cloudformation delete-stack \
  --stack-name ${PROJECT_NAME}-lustre \
  --region $REGION 2>/dev/null || echo "Stack does not exist"

echo "Waiting for Lustre stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name ${PROJECT_NAME}-lustre \
  --region $REGION 2>/dev/null || true
echo "✓ Lustre storage deleted"

# Delete EFS
echo -e "\n[4/5] Deleting EFS storage..."
aws cloudformation delete-stack \
  --stack-name ${PROJECT_NAME}-efs \
  --region $REGION 2>/dev/null || echo "Stack does not exist"

echo "Waiting for EFS stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name ${PROJECT_NAME}-efs \
  --region $REGION 2>/dev/null || true
echo "✓ EFS storage deleted"

# Delete network
echo -e "\n[5/5] Deleting network infrastructure..."
aws cloudformation delete-stack \
  --stack-name ${PROJECT_NAME}-network \
  --region $REGION 2>/dev/null || echo "Stack does not exist"

echo "Waiting for network stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name ${PROJECT_NAME}-network \
  --region $REGION 2>/dev/null || true
echo "✓ Network infrastructure deleted"

echo -e "\n=========================================="
echo "All resources cleaned up!"
echo "=========================================="
