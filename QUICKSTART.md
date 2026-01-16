# Quick Start Guide

Get started with BLAST performance testing in 4 steps.

## Prerequisites

- AWS CLI configured
- AWS account with appropriate permissions
- BLAST query file (FASTA format)

## Step-by-Step Deployment

### 1. Network Infrastructure (5 minutes)

```bash
export AWS_REGION=us-east-1
export PROJECT_NAME=blast-perf-test

aws cloudformation create-stack \
  --stack-name ${PROJECT_NAME}-network \
  --template-body file://01-network-infrastructure.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
  --region $AWS_REGION

aws cloudformation wait stack-create-complete \
  --stack-name ${PROJECT_NAME}-network \
  --region $AWS_REGION
```

### 2. EFS Storage (2-3 hours)

```bash
aws cloudformation create-stack \
  --stack-name ${PROJECT_NAME}-efs \
  --template-body file://02-efs-storage.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION

# Monitor progress
aws logs tail /${PROJECT_NAME}/efs/nt-download --follow --region $AWS_REGION
```

### 3. Lustre Storage (2-3 hours)

```bash
aws cloudformation create-stack \
  --stack-name ${PROJECT_NAME}-lustre \
  --template-body file://03-lustre-storage.yaml \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
    ParameterKey=S3BucketName,ParameterValue=blast-nt-lustre \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION

# Monitor progress
aws logs tail /${PROJECT_NAME}/lustre/nt-s3-copy --follow --region $AWS_REGION
```

### 4. AWS Batch Environment (5 minutes)

**Important**: Before deploying, ensure `04-batch-environment.yaml` has:
- Lustre mount command fixed
- Parameters for LustreFileSystemId and LustreMountName
- Instance type set to `optimal`

```bash
# Upload query file
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
QUERY_BUCKET="${PROJECT_NAME}-queries-${ACCOUNT_ID}"

aws s3 mb s3://$QUERY_BUCKET --region $AWS_REGION
aws s3 cp data/query.fasta s3://$QUERY_BUCKET/queries/query.fasta

# Get Lustre parameters
LUSTRE_FS_ID=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-lustre \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`LustreFileSystemId`].OutputValue' \
  --output text)

LUSTRE_MOUNT=$(aws cloudformation describe-stacks \
  --stack-name ${PROJECT_NAME}-lustre \
  --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`LustreMountName`].OutputValue' \
  --output text)

# Deploy Batch
aws cloudformation create-stack \
  --stack-name ${PROJECT_NAME}-batch \
  --template-body file://04-batch-environment.yaml \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=$PROJECT_NAME \
    ParameterKey=QueryS3Bucket,ParameterValue=$QUERY_BUCKET \
    ParameterKey=LustreFileSystemId,ParameterValue=$LUSTRE_FS_ID \
    ParameterKey=LustreMountName,ParameterValue=$LUSTRE_MOUNT \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION

aws cloudformation wait stack-create-complete \
  --stack-name ${PROJECT_NAME}-batch \
  --region $AWS_REGION
```

## Run Tests

```bash
./run_tests.sh
```

## Monitor Jobs

```bash
# Check job status
aws batch describe-jobs --jobs <JOB_ID> --region $AWS_REGION

# View logs
aws logs tail /${PROJECT_NAME}/batch/efs --follow --region $AWS_REGION
aws logs tail /${PROJECT_NAME}/batch/lustre --follow --region $AWS_REGION
aws logs tail /${PROJECT_NAME}/batch/s3 --follow --region $AWS_REGION
```

## Cleanup

```bash
./cleanup.sh
```

Or manually:

```bash
aws cloudformation delete-stack --stack-name ${PROJECT_NAME}-batch --region $AWS_REGION
aws cloudformation delete-stack --stack-name ${PROJECT_NAME}-lustre --region $AWS_REGION
aws cloudformation delete-stack --stack-name ${PROJECT_NAME}-efs --region $AWS_REGION
aws cloudformation delete-stack --stack-name ${PROJECT_NAME}-network --region $AWS_REGION

aws s3 rb s3://$QUERY_BUCKET --force --region $AWS_REGION
aws s3 rb s3://blast-nt-lustre-${AWS_REGION}-${ACCOUNT_ID} --force --region $AWS_REGION
```

## Troubleshooting

If jobs are stuck in RUNNABLE state, see [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md#troubleshooting) for solutions.

## Next Steps

- Review [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) for detailed instructions
- Analyze performance results
- Optimize costs with SPOT instances
