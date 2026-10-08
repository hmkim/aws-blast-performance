# BLAST Storage Performance Benchmark - Deployment Guide

Companion to [README.md](README.md) (architecture, why three methods, verified facts) and
[QUICKSTART.md](QUICKSTART.md) (copy-paste commands). This guide explains what each stack does,
which parameters matter, how to read the results and how to recover from the failure modes that
actually occur.

## What gets deployed

| Stack | Resources | Parameters that matter |
|---|---|---|
| `<project>-network` | VPC 10.0.0.0/16, 2 public + 2 private subnets (AZ a/b), IGW, NAT GW, **S3 gateway endpoint**, security groups (Batch; EFS 2049 from Batch; Lustre 988 from Batch and self) | `ProjectName` |
| `<project>-efs` | EFS (encrypted, generalPurpose, **Elastic** throughput) + 2 mount targets; staging EC2 host that syncs `<db>.*`, `<db>-nucl-metadata.json`, `taxdb.*` from the current NCBI prefix into `/mnt/efs/<db>/`, writes the SSM parameter `/<project>/efs/db-staging-status`, then stops itself | `BlastDbName` (nt), `StagingInstanceType` (m6i.4xlarge) |
| `<project>-lustre` | S3 bucket `<S3BucketName>-<account>`; FSx for Lustre SCRATCH_2 linked to that bucket (`AutoImportPolicy: NEW_CHANGED`); copy EC2 host that does a server-side `aws s3 sync` of the DB from NCBI into `s3://bucket/<db>/`, writes `/<project>/lustre/db-s3-copy-status`, stops itself | `BlastDbName`, `LustreStorageCapacity` (2400 for nt), `S3BucketName` |
| `<project>-batch` | 3 managed compute environments (same instance pool, min 0 vCPU), 3 job queues, 3 job definitions, launch templates (Lustre mount; NVMe RAID0), job role, log groups `/<project>/batch/{efs,lustre,s3}` | `BlastDbName`, `QueryS3Bucket`, `LustreFileSystemId`, `LustreMountName`, `InstanceTypes`, `JobVcpus`, `JobMemoryMiB`, `BlastPasses`, `BlastImage` |

The DB name must be identical in the three storage/compute stacks: the Batch job definitions derive
`-db /mnt/<layer>/<db>/<db>` from it.

## Choosing the database and the instance pool

| DB (2026-09 snapshot) | Size | Bytes to cache | Fits in RAM of | Use |
|---|---|---|---|---|
| `nt` | 1,199 GB, 390 volumes | 1,170 GB | nothing in the R family (max 768 GiB) | storage-bound benchmark: the storage layer is the bottleneck in every pass |
| `core_nt` | 301 GB, 91 volumes | 272 GB | r6id/r5d.12xlarge (384 GiB) | shows the "once cached, storage does not matter" regime: pass 2 is served from RAM |
| `ref_prok_rep_genomes` | 26.7 GB | - | any | representative of targeted-DB screening workloads |
| `ref_viruses_rep_genomes`, `16S_ribosomal_RNA` | 150 MB, 20 MB | - | any | smoke test of the pipeline |

The default pool `r6id.12xlarge,r5d.12xlarge` (48 vCPU, 384 GiB, 2 NVMe disks of 1,425 GB / 900 GB)
is the smallest d-type that holds nt on instance store. Keep the pool identical for the three
scenarios; changing CPU or RAM between scenarios invalidates the comparison. `JobMemoryMiB` must stay
below what the ECS agent registers for the instance (384 GiB installed -> about 386,000 MiB usable).

## Step by step

### 1. Network

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-network \
  --template-file 01-network-infrastructure.yaml \
  --parameter-overrides ProjectName=$PROJECT_NAME --region $AWS_REGION
```

### 2. EFS and staging

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-efs \
  --template-file 02-efs-storage.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ProjectName=$PROJECT_NAME BlastDbName=$BLAST_DB --region $AWS_REGION
```

The stack reaches `CREATE_COMPLETE` as soon as the host is running; the copy continues in the
background. Follow it with `aws logs tail /${PROJECT_NAME}/efs/db-staging --follow` and wait for the
SSM parameter `/${PROJECT_NAME}/efs/db-staging-status` to read `completed:<db>:<prefix>:<seconds>`.
Expect 2-3 h for nt: a single NFS client writes at most 1,500 MiB/s, and EFS Elastic throughput
charges $0.06 per GB written (about $72 for nt). The host stops itself when finished.

### 3. FSx for Lustre and S3 copy

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-lustre \
  --template-file 03-lustre-storage.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ProjectName=$PROJECT_NAME BlastDbName=$BLAST_DB \
    S3BucketName=blast-nt-lustre LustreStorageCapacity=$LUSTRE_GIB --region $AWS_REGION
```

The copy is S3 -> S3 (server-side); in us-east-1 there is no transfer charge, elsewhere $0.02/GB
leaves us-east-1. Follow `/${PROJECT_NAME}/lustre/db-s3-copy` and the parameter
`/${PROJECT_NAME}/lustre/db-s3-copy-status`. Because the bucket is empty when the file system is
created, the template sets `AutoImportPolicy: NEW_CHANGED`; the copied objects appear under
`/mnt/lustre/<db>/` as metadata only, and their contents are pulled from S3 on first read
(that first read is what the Lustre job measures as `db_setup_seconds`).

To pre-hydrate outside the job instead (not timed), run on any instance with the file system mounted:

```bash
nohup find /mnt/lustre/nt -type f -print0 | xargs -0 -n 50 -P 8 sudo lfs hsm_restore &
```

### 4. Query bucket and Batch

See QUICKSTART step 4. `QueryS3Key` defaults to `queries/query.fasta`. Results land in
`s3://<query-bucket>/results/<scenario>/results-<timestamp>.out` (pass 1 output).

### 5. Run and read the results

```bash
./run_tests.sh                    # or ./run_tests.sh efs
./analyze_performance.py --region $AWS_REGION --project $PROJECT_NAME [--run <timestamp>] [--json out.json]
```

Each job prints machine-readable lines to CloudWatch Logs:

```
METRIC scenario=lustre job=<id>
METRIC instance_type=r6id.12xlarge
METRIC db_setup_seconds=1830 (lustre hydration via vmtouch -t)      # efs: 0 ; s3: download, with db_bytes and mbps
METRIC pass=1 blast_seconds=2210 rows=92467 sha256=3f1c...          # cold
METRIC pass=2 blast_seconds=2190 rows=92467 sha256=3f1c...          # warm (== cold for nt, since nt > RAM)
METRIC total_seconds=4120
```

What to compare:

- `db_setup_seconds`: the one-time cost of filling the storage layer for this instance.
- `pass=1 blast_seconds`: storage-bound search time. For nt this is the number that ranks the
  three layers.
- `pass=2`: for a DB that fits in RAM (core_nt) all three scenarios should converge here; for nt it
  equals pass 1 and shows the storage layer again.
- `sha256`: the sorted-output hash must be identical across scenarios and runs. If it is not, the
  DBs are not the same snapshot (compare `SOURCE_PREFIX` on EFS and in the S3 copy).

Run each scenario at least twice; cloud storage throughput varies run to run (burst credits on
Lustre, EFS and S3 request-rate ramp-up).

## Troubleshooting

### Jobs stay in RUNNABLE

`aws batch describe-jobs ... --query 'jobs[].statusReason'`

- `MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT`: `JobVcpus`/`JobMemoryMiB` exceed every instance type
  in `InstanceTypes`. 48 / 370,000 fits a 12xlarge; do not request the full 384 GiB.
- No reason, compute environment stays at 0 instances: EC2 On-Demand R-instance vCPU quota too low
  (48 vCPU per concurrent job), or the instance types are not offered in the region/AZ
  (`aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=r6id.12xlarge`).
  Check `aws batch describe-compute-environments --query 'computeEnvironments[].{n:computeEnvironmentName,s:status,r:statusReason}'`.
- Spot: not used by default. If you switch a compute environment to `SPOT`, add `spotIamFleetRole`
  and expect interruptions during a 1-2 h job.

### Job fails immediately

- `aws: command not found`: the image has no AWS CLI. Keep `BlastImage` on the ElasticBLAST image or
  build your own with awscli.
- `No such file or directory: /mnt/nvme` or `No space left on device` in the `s3` scenario: the
  launch template did not run or the instance has no instance store. Check the instance's console
  output / `lsblk`; the pool must be d-type.
- `BLAST Database error: No alias or index file found for nucleotide database [/mnt/efs/nt/nt]`:
  staging is incomplete or the DB name differs between stacks. Verify the SSM status parameter and
  `ls /mnt/efs/nt | head` from the staging host (start it with `aws ec2 start-instances`).
- Lustre: `mount.lustre: ... Input/output error` or empty `/mnt/lustre`: security group 988 missing,
  compute in a different subnet than the file system (it is single-AZ; the Lustre compute environment
  is pinned to private subnet 1 for this reason), or `AutoImportPolicy` not applied. Check
  `aws fsx describe-file-systems --query 'FileSystems[].LustreConfiguration.DataRepositoryConfiguration'`.

### Staging never completes

- `aws logs tail /${PROJECT_NAME}/efs/db-staging` shows `fatal error: ... 403` on
  `s3://ncbi-blast-databases`: the instance role needs `s3:GetObject`/`s3:ListBucket` on that bucket
  (included) and an egress path to S3 (NAT or the gateway endpoint, both included).
- Status parameter missing: the role has `ssm:PutParameter` scoped to `/<project>/*`; a different
  `ProjectName` than the one used in the network stack breaks the `ImportValue`s and the scope.

### Lustre first pass is slow

SCRATCH_2 throughput is proportional to capacity: 200 MB/s per TiB baseline (2,400 GiB -> ~470 MB/s),
with bursts to 1,300 MB/s per TiB from network credits. A 1.2 TB first read at baseline is ~42 min.
For sustained throughput use `PERSISTENT_2` with 500 or 1,000 MB/s per TiB (change `DeploymentType`
and add `PerUnitStorageThroughput`; price $0.34 / $0.60 per GB-month), or increase capacity.

## Cleanup

```bash
./cleanup.sh
```

or delete `${PROJECT_NAME}-batch`, `-lustre`, `-efs`, `-network` in that order, then the two buckets
(`${PROJECT_NAME}-queries-<account>`, `blast-nt-lustre-<account>`). The staging instances belong to
their stacks and are deleted with them.

## Cost notes

See the README cost table. In short: EFS storage $0.30/GB-mo plus $0.06/GB written and $0.03/GB read
(the reads make each cold nt pass about $35); FSx SCRATCH_2 $0.14/GB-mo billed hourly for the
provisioned size; S3 copy $0.023/GB-mo; compute $3.6/h per 12xlarge while a job runs. Tear down the
storage between benchmark rounds.
