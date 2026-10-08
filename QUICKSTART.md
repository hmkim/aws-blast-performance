# Quick Start

Copy-paste deployment. Times are for `nt` (1.2 TB); a smoke test with
`BLAST_DB=ref_viruses_rep_genomes` (150 MB) finishes every step in minutes.

```bash
export AWS_REGION=us-east-1
export PROJECT_NAME=blast-perf-test
export BLAST_DB=nt                 # or ref_viruses_rep_genomes / 16S_ribosomal_RNA for a smoke test
export LUSTRE_GIB=2400             # 1200 is enough for small DBs; nt needs 2400
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## 1. Network (5 min)

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-network \
  --template-file 01-network-infrastructure.yaml \
  --parameter-overrides ProjectName=$PROJECT_NAME --region $AWS_REGION
```

## 2. EFS + DB staging (nt: 2-3 h)

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-efs \
  --template-file 02-efs-storage.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ProjectName=$PROJECT_NAME BlastDbName=$BLAST_DB --region $AWS_REGION

# progress
aws logs tail /${PROJECT_NAME}/efs/db-staging --follow --region $AWS_REGION
# done when this prints completed:<db>:<ncbi-prefix>:<seconds>
aws ssm get-parameter --name /${PROJECT_NAME}/efs/db-staging-status --region $AWS_REGION --query Parameter.Value --output text
```

The staging host stops itself when finished.

## 3. FSx for Lustre + S3 copy (nt: 1-2 h)

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-lustre \
  --template-file 03-lustre-storage.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ProjectName=$PROJECT_NAME BlastDbName=$BLAST_DB \
    S3BucketName=blast-nt-lustre LustreStorageCapacity=$LUSTRE_GIB --region $AWS_REGION

aws logs tail /${PROJECT_NAME}/lustre/db-s3-copy --follow --region $AWS_REGION
aws ssm get-parameter --name /${PROJECT_NAME}/lustre/db-s3-copy-status --region $AWS_REGION --query Parameter.Value --output text
```

Steps 2 and 3 are independent; run them in parallel.

## 4. Query bucket + AWS Batch (5 min)

```bash
QUERY_BUCKET=${PROJECT_NAME}-queries-${ACCOUNT_ID}
aws s3 mb s3://$QUERY_BUCKET --region $AWS_REGION
aws s3 cp data/query.fasta s3://$QUERY_BUCKET/queries/query.fasta

LUSTRE_FS_ID=$(aws cloudformation describe-stacks --stack-name ${PROJECT_NAME}-lustre --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`LustreFileSystemId`].OutputValue' --output text)
LUSTRE_MOUNT=$(aws cloudformation describe-stacks --stack-name ${PROJECT_NAME}-lustre --region $AWS_REGION \
  --query 'Stacks[0].Outputs[?OutputKey==`LustreMountName`].OutputValue' --output text)

aws cloudformation deploy --stack-name ${PROJECT_NAME}-batch \
  --template-file 04-batch-environment.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ProjectName=$PROJECT_NAME BlastDbName=$BLAST_DB \
    QueryS3Bucket=$QUERY_BUCKET LustreFileSystemId=$LUSTRE_FS_ID LustreMountName=$LUSTRE_MOUNT \
  --region $AWS_REGION
```

Optional overrides: `InstanceTypes=r6id.12xlarge,r5d.12xlarge` `JobVcpus=48` `JobMemoryMiB=370000`
`BlastPasses=2` `BlastImage=public.ecr.aws/ncbi-elasticblast/elasticblast-elb:1.4.0`.

## 5. Run

```bash
./run_tests.sh              # all three; refuses to start until both staging signals read "completed"
./run_tests.sh lustre s3    # subset
./run_tests.sh --concurrency 4   # 4 jobs per queue at once (up to 8 fit MaxvCpus=384); see README "Concurrency"
```

## 6. Monitor and analyze

```bash
aws batch describe-jobs --jobs <JOB_ID ...> --region $AWS_REGION --query 'jobs[].{name:jobName,status:status,reason:statusReason}' --output table
aws logs tail /${PROJECT_NAME}/batch/efs    --follow --region $AWS_REGION   # also .../lustre and .../s3
./analyze_performance.py --region $AWS_REGION --project $PROJECT_NAME [--run <timestamp>]   # p50/p95 + aggregate MB/s per scenario
```

## 7. Cleanup

```bash
./cleanup.sh        # or delete the four stacks in reverse order and the two buckets
```

FSx and EFS are billed hourly for provisioned/stored capacity: do not leave them up between runs.
