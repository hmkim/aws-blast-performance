#!/bin/bash
set -e

PROJECT_NAME="${PROJECT_NAME:-blast-perf-test}"
REGION="${REGION:-${AWS_REGION:-us-east-1}}"

echo "=========================================="
echo "BLAST Performance Test Infrastructure Cleanup"
echo "=========================================="

read -p "Delete all resources? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# Clean up S3 buckets
echo -e "\n[1/6] Cleaning up S3 buckets..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
QUERY_BUCKET="${PROJECT_NAME}-queries-${ACCOUNT_ID}"
# The Lustre bucket name is a stack parameter (S3BucketName + account id). Read the real name from
# the stack while it still exists instead of guessing the prefix; fall back to the QUICKSTART default.
LUSTRE_BUCKET=$(aws cloudformation describe-stack-resource --stack-name ${PROJECT_NAME}-lustre \
  --logical-resource-id S3Bucket --region $REGION \
  --query 'StackResourceDetail.PhysicalResourceId' --output text 2>/dev/null || true)
[ -z "$LUSTRE_BUCKET" ] || [ "$LUSTRE_BUCKET" = "None" ] && LUSTRE_BUCKET="${LUSTRE_BUCKET_PREFIX:-blast-nt-lustre}-${ACCOUNT_ID}"

echo "Deleting query bucket: $QUERY_BUCKET"
aws s3 rb s3://$QUERY_BUCKET --force --region $REGION 2>/dev/null || echo "Bucket does not exist"

# CloudFormation cannot delete a bucket that still holds the DB copy (DELETE_FAILED on S3Bucket),
# so empty and remove it here first; the stack then skips the already-missing resource.
echo "Deleting Lustre bucket: $LUSTRE_BUCKET"
aws s3 rb s3://$LUSTRE_BUCKET --force --region $REGION 2>/dev/null || echo "Bucket does not exist"

# The staging and copy hosts write their status to SSM outside the stacks (02/03 user data).
echo -e "\n[2/6] Deleting SSM status parameters..."
for P in /${PROJECT_NAME}/efs/db-staging-status /${PROJECT_NAME}/lustre/db-s3-copy-status; do
  aws ssm delete-parameter --name "$P" --region $REGION 2>/dev/null && echo "Deleted $P" || echo "$P not present"
done

# Delete Batch environment
echo -e "\n[3/6] Deleting AWS Batch environment..."
aws cloudformation delete-stack \
  --stack-name ${PROJECT_NAME}-batch \
  --region $REGION 2>/dev/null || echo "Stack does not exist"

echo "Waiting for Batch stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name ${PROJECT_NAME}-batch \
  --region $REGION 2>/dev/null || true
echo "✓ Batch environment deleted"

# Delete Lustre
echo -e "\n[4/6] Deleting Lustre storage..."
aws cloudformation delete-stack \
  --stack-name ${PROJECT_NAME}-lustre \
  --region $REGION 2>/dev/null || echo "Stack does not exist"

echo "Waiting for Lustre stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name ${PROJECT_NAME}-lustre \
  --region $REGION 2>/dev/null || true
echo "✓ Lustre storage deleted"

# Delete EFS
echo -e "\n[5/6] Deleting EFS storage..."
aws cloudformation delete-stack \
  --stack-name ${PROJECT_NAME}-efs \
  --region $REGION 2>/dev/null || echo "Stack does not exist"

echo "Waiting for EFS stack deletion..."
aws cloudformation wait stack-delete-complete \
  --stack-name ${PROJECT_NAME}-efs \
  --region $REGION 2>/dev/null || true
echo "✓ EFS storage deleted"

# Delete network
echo -e "\n[6/6] Deleting network infrastructure..."
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
