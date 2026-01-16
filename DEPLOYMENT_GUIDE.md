# BLAST Storage Performance Comparison Infrastructure Deployment Guide

## Overview

Deployment and troubleshooting guide for AWS infrastructure comparing BLAST performance across three storage scenarios.

## Deployed Resources

### Network (VPC)
- VPC: 10.0.0.0/16
- Public Subnets: 2 (availability zones a, b)
- Private Subnets: 2 (availability zones a, b)
- NAT Gateway: 1
- Internet Gateway: 1

### Storage
- **EFS**: 810 GB NT database
- **FSx for Lustre**: 1200 GB NT database
- **S3**: Query files and Lustre backup

### AWS Batch
- Job Queues: 3 (EFS, Lustre, S3)
- Compute Environments: 3 (384 vCPU each)
- Job Definitions: 3 (32 vCPU, 768 GB memory)

## Deployment Steps

### Step 1: Network Infrastructure

```bash
aws cloudformation create-stack \
  --stack-name blast-perf-test-network \
  --template-body file://01-network-infrastructure.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=blast-perf-test \
  --region <YOUR_REGION>

aws cloudformation wait stack-create-complete \
  --stack-name blast-perf-test-network \
  --region <YOUR_REGION>
```

### Step 2: EFS Storage and NT DB Upload

```bash
aws cloudformation create-stack \
  --stack-name blast-perf-test-efs \
  --template-body file://02-efs-storage.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=blast-perf-test \
  --capabilities CAPABILITY_IAM \
  --region <YOUR_REGION>

aws cloudformation wait stack-create-complete \
  --stack-name blast-perf-test-efs \
  --region <YOUR_REGION>

# Monitor NT DB download progress (~2-3 hours)
aws logs tail /blast-perf-test/efs/nt-download --follow --region <YOUR_REGION>
```

### Step 3: Lustre Storage and S3 Copy

```bash
BUCKET_NAME="blast-nt-lustre"

aws cloudformation create-stack \
  --stack-name blast-perf-test-lustre \
  --template-body file://03-lustre-storage.yaml \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=blast-perf-test \
    ParameterKey=S3BucketName,ParameterValue=$BUCKET_NAME \
  --capabilities CAPABILITY_IAM \
  --region <YOUR_REGION>

aws cloudformation wait stack-create-complete \
  --stack-name blast-perf-test-lustre \
  --region <YOUR_REGION>

# Monitor S3 copy progress (~2-3 hours)
aws logs tail /blast-perf-test/lustre/nt-s3-copy --follow --region <YOUR_REGION>
```

### Step 4: AWS Batch Environment

#### 4-1. Upload Query Files

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
QUERY_BUCKET="blast-perf-test-queries-${ACCOUNT_ID}"

aws s3 mb s3://$QUERY_BUCKET --region <YOUR_REGION>
aws s3 cp ../data/query.fasta s3://$QUERY_BUCKET/queries/query.fasta
```

#### 4-2. Batch Stack Deployment

**Important**: Modifications required in 04-batch-environment.yaml

1. **Fix Lustre mount command**:
```yaml
# Incorrect:
mount -t lustre ${LustreFileSystem.DNSName}@tcp:/fsx /mnt/lustre

# Correct:
mount -t lustre ${LustreFileSystemId}.fsx.${AWS::Region}.amazonaws.com@tcp:/${LustreMountName} /mnt/lustre
```

2. **Add to Parameters section**:
```yaml
Parameters:
  LustreFileSystemId:
    Type: String
    Description: FSx for Lustre file system ID

  LustreMountName:
    Type: String
    Description: FSx for Lustre mount name
```

3. **Set instance type to optimal** (resolves capacity issues):
```yaml
ComputeResources:
  InstanceTypes:
    - optimal  # Use optimal instead of specific instance types
```

#### 4-3. Deploy

```bash
LUSTRE_FS_ID=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-lustre \
  --region <YOUR_REGION> \
  --query 'Stacks[0].Outputs[?OutputKey==`LustreFileSystemId`].OutputValue' \
  --output text)

LUSTRE_MOUNT=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-lustre \
  --region <YOUR_REGION> \
  --query 'Stacks[0].Outputs[?OutputKey==`LustreMountName`].OutputValue' \
  --output text)

aws cloudformation create-stack \
  --stack-name blast-perf-test-batch \
  --template-body file://04-batch-environment.yaml \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=blast-perf-test \
    ParameterKey=QueryS3Bucket,ParameterValue=$QUERY_BUCKET \
    ParameterKey=LustreFileSystemId,ParameterValue=$LUSTRE_FS_ID \
    ParameterKey=LustreMountName,ParameterValue=$LUSTRE_MOUNT \
  --capabilities CAPABILITY_IAM \
  --region <YOUR_REGION>

aws cloudformation wait stack-create-complete \
  --stack-name blast-perf-test-batch \
  --region <YOUR_REGION>
```

## Running BLAST Jobs

### Automated (Recommended)

```bash
./run_tests.sh
```

### Manual Execution

#### EFS Scenario
```bash
JOB_QUEUE=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobQueueEFSArn`].OutputValue' \
  --output text --region <YOUR_REGION>)

JOB_DEF=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobDefinitionEFS`].OutputValue' \
  --output text --region <YOUR_REGION>)

aws batch submit-job \
  --job-name blast-efs-test-$(date +%Y%m%d-%H%M%S) \
  --job-queue $JOB_QUEUE \
  --job-definition $JOB_DEF \
  --region <YOUR_REGION>
```

#### Lustre Scenario
```bash
JOB_QUEUE=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobQueueLustreArn`].OutputValue' \
  --output text --region <YOUR_REGION>)

JOB_DEF=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobDefinitionLustre`].OutputValue' \
  --output text --region <YOUR_REGION>)

aws batch submit-job \
  --job-name blast-lustre-test-$(date +%Y%m%d-%H%M%S) \
  --job-queue $JOB_QUEUE \
  --job-definition $JOB_DEF \
  --region <YOUR_REGION>
```

#### S3 Scenario
```bash
JOB_QUEUE=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobQueueS3Arn`].OutputValue' \
  --output text --region <YOUR_REGION>)

JOB_DEF=$(aws cloudformation describe-stacks \
  --stack-name blast-perf-test-batch \
  --query 'Stacks[0].Outputs[?OutputKey==`JobDefinitionS3`].OutputValue' \
  --output text --region <YOUR_REGION>)

aws batch submit-job \
  --job-name blast-s3-test-$(date +%Y%m%d-%H%M%S) \
  --job-queue $JOB_QUEUE \
  --job-definition $JOB_DEF \
  --region <YOUR_REGION>
```

## Monitoring

### Check Job Status
```bash
aws batch describe-jobs --jobs <JOB_ID> --region <YOUR_REGION>
```

### CloudWatch Logs
```bash
# EFS
aws logs tail /blast-perf-test/batch/efs --follow --region <YOUR_REGION>

# Lustre
aws logs tail /blast-perf-test/batch/lustre --follow --region <YOUR_REGION>

# S3
aws logs tail /blast-perf-test/batch/s3 --follow --region <YOUR_REGION>
```

## Troubleshooting

### 1. Batch Jobs Stuck in RUNNABLE State

**Symptom**: 
```
MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT - The job resource requirement (vCPU/memory/GPU) 
is higher than that can be met by the CE(s) attached to the job queue.
```

**Causes**: 
- Regional capacity shortage for specific instance types
- Job Definition vCPU requirements too high

**Solutions**:

1. **Change instance type to optimal** (recommended):
```yaml
ComputeResources:
  InstanceTypes:
    - optimal
```

2. **Reduce vCPU requirements**:
```yaml
# In Job Definition
Vcpus: 32  # Gradually reduce: 96 → 48 → 32
```

3. **Add multiple instance types**:
```yaml
InstanceTypes:
  - r5.8xlarge
  - r5d.8xlarge
  - r5.12xlarge
  - r5d.12xlarge
```

4. **Use SPOT instances**:
```yaml
ComputeResources:
  Type: SPOT
  BidPercentage: 100
```

### 2. Lustre Mount Failure

**Symptom**: Job starts but Lustre mount fails

**Solution**: 
- Fix Lustre mount command in 04-batch-environment.yaml
- Add LustreFileSystemId and LustreMountName to Parameters

### 3. EC2 Instances Not Starting

**Check**:
```bash
# Compute Environment status
aws batch describe-compute-environments \
  --region <YOUR_REGION> \
  --query 'computeEnvironments[*].{Name:computeEnvironmentName,Status:status,DesiredvCpus:computeResources.desiredvCpus}'

# Instance type availability
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=r5.12xlarge \
  --region <YOUR_REGION>
```

**Solutions**:
- Use different region (us-east-1, us-west-2)
- Use SPOT instances
- Use optimal instance type

### 4. Job Queue References Old Compute Environment

**Check**:
```bash
aws batch describe-job-queues \
  --job-queues <QUEUE_NAME> \
  --region <YOUR_REGION> \
  --query 'jobQueues[0].computeEnvironmentOrder[*].computeEnvironment'
```

**Solution**: 
- Cancel existing jobs and resubmit
- Wait for CloudFormation stack update to complete

## Resource Cleanup

```bash
# Delete in reverse order
aws cloudformation delete-stack --stack-name blast-perf-test-batch --region <YOUR_REGION>
aws cloudformation delete-stack --stack-name blast-perf-test-lustre --region <YOUR_REGION>
aws cloudformation delete-stack --stack-name blast-perf-test-efs --region <YOUR_REGION>
aws cloudformation delete-stack --stack-name blast-perf-test-network --region <YOUR_REGION>

# Delete S3 buckets
aws s3 rb s3://$QUERY_BUCKET --force --region <YOUR_REGION>
aws s3 rb s3://blast-nt-lustre-<REGION>-${ACCOUNT_ID} --force --region <YOUR_REGION>
```

## Cost Optimization Tips

1. **Use SPOT instances**: Up to 90% cost savings
2. **Delete resources immediately after job completion**
3. **Delete EFS/Lustre when not in use**
4. **Watch NAT Gateway costs**: Hourly charges apply

## Expected Performance

| Scenario | DB Load Time | BLAST Execution | Total Time |
|----------|-------------|-----------------|------------|
| EFS | 0s | 15-20 min | 15-20 min |
| Lustre | 0s | 10-15 min | 10-15 min |
| S3 | 30-60 min | 10-15 min | 40-75 min |

## Key Lessons Learned

1. **Check regional capacity**: Verify instance type availability before deployment
2. **Use optimal instance type**: More flexible than specifying specific types
3. **Gradual vCPU reduction**: Adjust 96 → 48 → 32 incrementally
4. **Validate CloudFormation parameters**: Watch for missing Lustre parameters
5. **Wait for stack updates**: Prevent referencing old Compute Environments

## References

- [AWS Batch Documentation](https://docs.aws.amazon.com/batch/)
- [Amazon EFS Performance](https://docs.aws.amazon.com/efs/latest/ug/performance.html)
- [FSx for Lustre Performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html)
- [NCBI BLAST Documentation](https://blast.ncbi.nlm.nih.gov/doc/blast-help/)
