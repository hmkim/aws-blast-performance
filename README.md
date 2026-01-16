# AWS BLAST Performance Benchmark

AWS infrastructure for comparing BLAST nucleotide database performance across EFS, FSx for Lustre, and S3 storage using AWS Batch.

## Overview

This project provides CloudFormation templates and scripts to deploy and benchmark BLAST (Basic Local Alignment Search Tool) performance across three AWS storage solutions:

- **Amazon EFS**: Network file system with elastic throughput
- **FSx for Lustre**: High-performance parallel file system
- **Amazon S3**: Object storage with local NVMe caching

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         VPC (10.0.0.0/16)                   │
├─────────────────────────────────────────────────────────────┤
│  Public Subnets          │  Private Subnets                 │
│  - NAT Gateway           │  - AWS Batch Compute             │
│                          │  - EFS Mount Targets             │
│                          │  - FSx Lustre                    │
└─────────────────────────────────────────────────────────────┘

Storage Layer:
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│     EFS      │  │    Lustre    │  │   S3 + NVMe  │
│   810 GB     │  │   1200 GB    │  │   Download   │
└──────────────┘  └──────────────┘  └──────────────┘
       ↓                 ↓                  ↓
┌──────────────────────────────────────────────────┐
│           AWS Batch (32 vCPU, 768 GB)            │
└──────────────────────────────────────────────────┘
```

## Features

- **Automated Deployment**: CloudFormation templates for complete infrastructure
- **Three Storage Scenarios**: Compare EFS, Lustre, and S3 performance
- **AWS Batch Integration**: Scalable compute for BLAST jobs
- **Monitoring**: CloudWatch Logs for job tracking
- **Cost Optimization**: SPOT instance support and cleanup scripts

## Quick Start

### Prerequisites

- AWS CLI configured with appropriate credentials
- BLAST query file (FASTA format)
- Sufficient AWS service quotas for EC2, EFS, and FSx

### Deployment

1. **Clone the repository**
```bash
git clone https://github.com/hmkim/aws-blast-performance.git
cd aws-blast-performance
```

2. **Deploy infrastructure** (4 steps, ~3-4 hours total)
```bash
# Set your AWS region
export AWS_REGION=us-east-1

# Step 1: Network (5 min)
aws cloudformation create-stack \
  --stack-name blast-perf-test-network \
  --template-body file://01-network-infrastructure.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=blast-perf-test \
  --region $AWS_REGION

# Step 2: EFS + NT DB download (2-3 hours)
aws cloudformation create-stack \
  --stack-name blast-perf-test-efs \
  --template-body file://02-efs-storage.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=blast-perf-test \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION

# Step 3: Lustre + S3 copy (2-3 hours)
aws cloudformation create-stack \
  --stack-name blast-perf-test-lustre \
  --template-body file://03-lustre-storage.yaml \
  --parameters \
    ParameterKey=ProjectName,ParameterValue=blast-perf-test \
    ParameterKey=S3BucketName,ParameterValue=blast-nt-lustre \
  --capabilities CAPABILITY_IAM \
  --region $AWS_REGION

# Step 4: AWS Batch (5 min)
# See DEPLOYMENT_GUIDE.md for detailed instructions
```

3. **Run BLAST tests**
```bash
./run_tests.sh
```

4. **Monitor results**
```bash
aws logs tail /blast-perf-test/batch/efs --follow --region $AWS_REGION
```

## Documentation

- **[Deployment Guide](DEPLOYMENT_GUIDE.md)**: Complete deployment instructions with troubleshooting
- **[Deployment Guide (한글)](DEPLOYMENT_GUIDE.ko.md)**: 한국어 배포 가이드
- **[Quick Start](QUICKSTART.md)**: Simplified deployment steps

## Expected Performance

| Storage | DB Load Time | BLAST Execution | Total Time |
|---------|-------------|-----------------|------------|
| EFS | 0s (pre-loaded) | 15-20 min | 15-20 min |
| Lustre | 0s (pre-loaded) | 10-15 min | 10-15 min |
| S3 | 30-60 min | 10-15 min | 40-75 min |

## Cost Estimate

**Monthly costs** (assuming 1 test run per scenario):
- Network: ~$50 (NAT Gateway)
- Storage: ~$380 (EFS + Lustre + S3)
- Compute: ~$5-10 (AWS Batch)
- **Total**: ~$435-440/month

**Cost optimization**:
- Use SPOT instances (up to 90% savings)
- Delete resources after testing
- Use S3 Intelligent-Tiering

## Troubleshooting

### Common Issues

**1. Jobs stuck in RUNNABLE state**
- **Cause**: Regional EC2 capacity shortage
- **Solution**: Use `optimal` instance type in Compute Environment

**2. Lustre mount failure**
- **Cause**: Incorrect mount command in CloudFormation
- **Solution**: See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md#2-lustre-mount-failure)

**3. EC2 instances not starting**
- **Cause**: Instance type unavailable in region
- **Solution**: Try different region or use SPOT instances

See [DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md#troubleshooting) for complete troubleshooting guide.

## Cleanup

```bash
# Delete in reverse order
aws cloudformation delete-stack --stack-name blast-perf-test-batch --region $AWS_REGION
aws cloudformation delete-stack --stack-name blast-perf-test-lustre --region $AWS_REGION
aws cloudformation delete-stack --stack-name blast-perf-test-efs --region $AWS_REGION
aws cloudformation delete-stack --stack-name blast-perf-test-network --region $AWS_REGION

# Delete S3 buckets
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 rb s3://blast-perf-test-queries-${ACCOUNT_ID} --force --region $AWS_REGION
aws s3 rb s3://blast-nt-lustre-${AWS_REGION}-${ACCOUNT_ID} --force --region $AWS_REGION
```

## Project Structure

```
.
├── 01-network-infrastructure.yaml    # VPC, subnets, gateways
├── 02-efs-storage.yaml              # EFS file system + NT DB download
├── 03-lustre-storage.yaml           # FSx for Lustre + S3 backup
├── 04-batch-environment.yaml        # AWS Batch compute environments
├── run_tests.sh                     # Execute all three scenarios
├── cleanup.sh                       # Delete all resources
├── DEPLOYMENT_GUIDE.md              # Complete deployment guide
└── DEPLOYMENT_GUIDE.ko.md           # Korean deployment guide
```

## Requirements

- AWS Account with appropriate permissions
- AWS CLI v2.x
- BLAST query file in FASTA format
- ~810 GB NCBI NT database (automatically downloaded)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## References

- [AWS Batch Documentation](https://docs.aws.amazon.com/batch/)
- [Amazon EFS Performance](https://docs.aws.amazon.com/efs/latest/ug/performance.html)
- [FSx for Lustre Performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html)
- [NCBI BLAST Documentation](https://blast.ncbi.nlm.nih.gov/doc/blast-help/)

## Acknowledgments

This project was developed to benchmark genomics workload performance on AWS storage solutions.
