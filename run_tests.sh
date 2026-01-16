#!/bin/bash
set -e

PROJECT_NAME="${PROJECT_NAME:-blast-perf-test}"
REGION="${REGION:-us-east-1}"

echo "=========================================="
echo "BLAST Performance Test Execution"
echo "=========================================="

# Get Job Queue and Definition
echo "Retrieving Job Queue and Definition..."

JOB_QUEUE_EFS=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobQueueEFSArn`].OutputValue' \
  --output text \
  --region $REGION)

JOB_DEF_EFS=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobDefinitionEFS`].OutputValue' \
  --output text \
  --region $REGION)

JOB_QUEUE_LUSTRE=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobQueueLustreArn`].OutputValue' \
  --output text \
  --region $REGION)

JOB_DEF_LUSTRE=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobDefinitionLustre`].OutputValue' \
  --output text \
  --region $REGION)

JOB_QUEUE_S3=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobQueueS3Arn`].OutputValue' \
  --output text \
  --region $REGION)

JOB_DEF_S3=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobDefinitionS3`].OutputValue' \
  --output text \
  --region $REGION)

TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Scenario 1: EFS
echo -e "\n[1/3] Running EFS scenario..."
JOB_ID_EFS=$(aws batch submit-job \
  --job-name blast-efs-test-$TIMESTAMP \
  --job-queue $JOB_QUEUE_EFS \
  --job-definition $JOB_DEF_EFS \
  --region $REGION \
  --query 'jobId' \
  --output text)

echo "✓ EFS job submitted (Job ID: $JOB_ID_EFS)"
echo "  Logs: aws logs tail /blast-perf-test/batch/efs --follow --region $REGION"

# Scenario 2: Lustre
echo -e "\n[2/3] Running Lustre scenario..."
JOB_ID_LUSTRE=$(aws batch submit-job \
  --job-name blast-lustre-test-$TIMESTAMP \
  --job-queue $JOB_QUEUE_LUSTRE \
  --job-definition $JOB_DEF_LUSTRE \
  --region $REGION \
  --query 'jobId' \
  --output text)

echo "✓ Lustre job submitted (Job ID: $JOB_ID_LUSTRE)"
echo "  Logs: aws logs tail /blast-perf-test/batch/lustre --follow --region $REGION"

# Scenario 3: S3
echo -e "\n[3/3] Running S3 scenario..."
JOB_ID_S3=$(aws batch submit-job \
  --job-name blast-s3-test-$TIMESTAMP \
  --job-queue $JOB_QUEUE_S3 \
  --job-definition $JOB_DEF_S3 \
  --region $REGION \
  --query 'jobId' \
  --output text)

echo "✓ S3 job submitted (Job ID: $JOB_ID_S3)"
echo "  Logs: aws logs tail /blast-perf-test/batch/s3 --follow --region $REGION"

echo -e "\n=========================================="
echo "All jobs submitted"
echo "=========================================="
echo ""
echo "Job IDs:"
echo "  EFS:    $JOB_ID_EFS"
echo "  Lustre: $JOB_ID_LUSTRE"
echo "  S3:     $JOB_ID_S3"
echo ""
echo "Check job status:"
echo "  aws batch describe-jobs --jobs $JOB_ID_EFS $JOB_ID_LUSTRE $JOB_ID_S3 --region $REGION"
echo ""
echo "Monitor logs:"
echo "  # EFS"
echo "  aws logs tail /blast-perf-test/batch/efs --follow --region $REGION"
echo ""
echo "  # Lustre"
echo "  aws logs tail /blast-perf-test/batch/lustre --follow --region $REGION"
echo ""
echo "  # S3"
echo "  aws logs tail /blast-perf-test/batch/s3 --follow --region $REGION"
echo ""
echo "Performance analysis (after jobs complete):"
echo "  ./analyze_performance.py $REGION"
