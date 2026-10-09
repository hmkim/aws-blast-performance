# AWS BLAST Performance Benchmark

CloudFormation templates and scripts that run the same `blastn` search against the same NCBI BLAST
database on AWS Batch, three times, changing only the storage layer the database is read from:

| Scenario | Storage layer | How the DB gets there |
|---|---|---|
| `efs` | Amazon EFS (Regional, Elastic throughput, NFS 4.1 + TLS) | staged once by an EC2 host (`aws s3 sync` from NCBI into the file system) |
| `lustre` | Amazon FSx for Lustre (SCRATCH_2, linked to an S3 bucket) | S3 -> S3 copy of the DB into your bucket; Lustre lazy-loads file contents on first read |
| `s3` | Amazon S3 -> instance-store NVMe (RAID0, ext4) | each compute instance downloads the DB at job start (this is what [ElasticBLAST](https://github.com/ncbi/elastic-blast) does on every node) |

Everything else is held constant: identical instance pool, identical query, identical BLAST+ build,
identical DB snapshot (the NCBI dated prefix is recorded in `SOURCE_PREFIX`), two consecutive
`blastn` passes per job so cold (storage-bound) and warm (page-cache) behaviour are measured separately.

> **Status (2026-10-08).** The templates were reviewed against the live NCBI bucket layout, the current
> AWS Batch defaults and the AWS price list, and several defects that prevented the original version from
> producing any result were fixed (see [What was verified](#what-was-verified-2026-10-08)). The
> performance table below is a **model, not a measurement**, until `./run_tests.sh` has been run with
> these templates.

## Architecture

### The database and its origin

NCBI publishes pre-formatted BLAST databases in the public bucket `s3://ncbi-blast-databases`
(us-east-1, [AWS Open Data](https://registry.opendata.aws/ncbi-blast-databases/)). The layout matters
for every template here:

```
s3://ncbi-blast-databases/
├── latest-dir                      <- one line: the dated prefix that is current (e.g. 2026-09-28-09-20-02)
├── 2026-09-28-09-20-02/            <- DBs are UNPACKED volume files under a dated prefix (no tar.gz)
│   ├── nt.000.nhd  nt.000.nhi  nt.000.nhr  nt.000.nin  nt.000.nnd  nt.000.nni  nt.000.nog  nt.000.nsq
│   ├── ...        390 volumes, 3,454 files, 1,199 GB total                                       (nt, 2026-09)
│   ├── nt.nal                       <- alias that lists the volumes; `-db <dir>/nt` opens this
│   ├── nt-nucl-metadata.json        <- bytes-total 1,199 GB, bytes-to-cache 1,170 GB, 4.66 Tbases
│   ├── core_nt.00.* ... core_nt.90.*   301 GB (272 GB to cache)       ref_prok_rep_genomes.*  26.7 GB
│   ├── taxdb.btd  taxdb.bti         <- taxonomy names, needed for staxids/sscinames in outfmt 6
│   └── <about 60 other databases>
└── 2026-07-14-01-05-02/, 2026-07-21-01-05-02/   <- older snapshots (a few are kept)
```

BLAST+ opens the volume files with `mmap` and streams the `.nsq` sequence volumes, so the database
has to live on a **POSIX block file system** at search time. Reading it straight from S3 is not possible;
some copy of the 1.2 TB has to be made, and the three scenarios are three answers to *where* and *how often*.

### Three storage paths to the same compute

```
                 s3://ncbi-blast-databases/<latest-dir>/   (us-east-1, 1.2 TB for nt)
                            │
     ┌──────────────────────┼───────────────────────────────────┐
     │ (1) once             │ (2) once, S3 -> S3 (server-side)   │ (3) at every job start, if the
     │ EC2 staging host     │ into s3://<your-bucket>/nt/        │     instance does not have it yet
     │ aws s3 sync -> NFS   │ = Lustre data repository           │     aws s3 sync -> local NVMe
     ▼                      ▼                                    ▼
┌───────────────────┐  ┌────────────────────────┐   ┌──────────────────────────────┐
│ Amazon EFS        │  │ FSx for Lustre SCRATCH_2│   │ instance store NVMe          │
│ Regional, 2 AZ    │  │ 2,400 GiB, single AZ    │   │ r6id.12xlarge: 2 x 1,425 GB  │
│ Elastic throughput│  │ 200 MB/s/TiB baseline,  │   │ RAID0 ext4, lives and dies   │
│ 1,500 MiB/s/client│  │ 1,300 MB/s/TiB burst    │   │ with the instance            │
│ $0.30/GB-mo       │  │ lazy-loads from S3 on   │   │ $0 (part of the instance)    │
│ + $0.03/GB read   │  │ first read; $0.14/GB-mo │   │ S3 copy $0.023/GB-mo         │
└────────┬──────────┘  └───────────┬────────────┘   └───────────────┬──────────────┘
 ECS EfsVolumeConfiguration   launch template: dnf install    launch template: mdadm RAID0,
 (TLS), /mnt/efs ro           lustre-client + mount,          mkfs.ext4, mount /mnt/nvme;
                              /mnt/lustre ro (Host volume)    /mnt/nvme rw (Host volume)
         │                          │                              │
         └──────────────────────────┼──────────────────────────────┘
                                    ▼
      AWS Batch, 3 managed compute environments with the SAME instance pool
      (r6id.12xlarge | r5d.12xlarge: 48 vCPU, 384 GiB, local NVMe), min 0 vCPU
      job = elasticblast-elb:1.4.0 image (BLAST+ 2.17 + aws cli + vmtouch)
            blastn -db .../nt -num_threads 48 -evalue 1e-3 -max_target_seqs 5 -outfmt 6, x2 passes
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
      s3://<query-bucket>/results/<scenario>/   CloudWatch Logs /<project>/batch/<scenario>
                                                "METRIC key=value" lines -> analyze_performance.py
```

Network: one VPC, 2 public + 2 private subnets, NAT Gateway, and an **S3 gateway endpoint** so the
terabyte-scale S3 traffic does not pay NAT data-processing ($0.045/GB, about $54 per DB pull).
Security groups: NFS 2049 (EFS) and Lustre 988 only from the Batch instances.

### The three layers every scenario passes through

```
layer 1  origin        s3://ncbi-blast-databases (or your in-region copy)
            │  copied by: staging host (EFS) / S3 copy + lazy load (Lustre) / job itself (NVMe)
layer 2  block FS      what blastn mmap()s:  /mnt/efs/nt | /mnt/lustre/nt | /mnt/nvme/nt
            │  read through by the kernel page cache, per node
layer 3  RAM           decides the search speed. nt needs 1,170 GB to be fully cached; the largest
                       R-family instance has 768 GiB, so an nt search is ALWAYS storage-bound.
                       core_nt (272 GB) fits in a 384 GiB node: pass 2 then runs from RAM.
```

The storage layer therefore matters in two regimes, and the benchmark measures both:
cold pass (layer 2 throughput; the only regime that exists for `nt`), and the one-time cost of
filling layer 2 (`db_setup_seconds`: 0 for pre-staged EFS, lazy-load hydration for Lustre, the
download for NVMe).

## Why three methods

| Method | What it is the answer to | What the benchmark tells you | Known limits going in |
|---|---|---|---|
| **S3 -> local NVMe** (baseline) | "No shared storage at all": every instance stages its own copy. This is ElasticBLAST's model and the cheapest standing cost. | Per-instance staging time and MB/s; NVMe read throughput during the cold pass. Amortised over the jobs one instance serves (`.done` marker lets later jobs on the same instance skip the download). | Pays the full download on every new instance (and every Spot replacement); 1.2 TB at 18.75 Gbit/s is at least ~9 minutes. |
| **EFS** | "Simplest shared POSIX file system": no capacity planning, multi-AZ, mounted by ECS natively. | Whether a single NFS client's cap (1,500 MiB/s with efs-utils 2.x) and the Elastic-throughput read charge are acceptable for a streaming scan of the DB. | **Disqualified at nt scale by its price structure, before any measurement:** $0.03/GB read means every cold pass over nt costs about **$35** in EFS reads alone, and because nt (1,170 GB to cache) cannot stay in RAM on any R instance, *every* pass is cold; the per-client cap (about 1,500 MiB/s) puts a floor of about 12 min under a full scan, and adding nodes does not raise the per-node cap. Suited to DBs of tens of GB that are read into RAM once. |
| **FSx for Lustre** | "Shared parallel file system for many concurrent nodes": HPC standard, S3-linked, no per-read charge, throughput scales with provisioned size. | Hydration time from S3 on first touch, then steady-state read throughput against many clients; whether 2,400 GiB SCRATCH_2 (about 470 MB/s baseline, bursts to about 3 GB/s) keeps up with a 48-thread blastn. | Single AZ; billed hourly for provisioned capacity whether used or not; a 1,200 GiB file system would be 93 % full with nt and too slow (234 MB/s baseline). |

EFS is kept in the matrix so the three storage classes are compared on the same footing, but its
verdict for `nt` does not depend on the measurement: at $0.03/GB a workload of 2,000 searches a day
would pay about $70,000 a day in EFS reads alone, and the Bursting/Provisioned modes that remove the
read charge give either about 60 MiB/s at 1.2 TB stored (a 5-hour scan) or 500 MiB/s for about
$3,000 a month. **Run the `efs` scenario only with `core_nt` or a small DB** (`BlastDbName=core_nt`
or the [small-DB variant](#small-db-variant-targeted-screening) below); against nt it adds about
$140 of staging writes and reads to a round and answers a question the price list already settled.

Which one wins between the remaining two depends on how many jobs share one copy of the database
before it is thrown away:
a daily cadence of thousands of jobs over `nt` favours a shared file system; a few large batch
searches a month favour per-instance NVMe (or ElasticBLAST). This repository exists to put numbers on
that trade-off instead of guessing. The numbers are in, for one reader: on `nt` a cold `blastn`
pass took **15 min from local NVMe and 2 h 19 min from FSx for Lustre** (the search faults 8 KB pages
through `mmap` once the DB is larger than RAM, and a network file system serves those one round trip
at a time), so the shared file system is the *staging source*, not the layer the search reads from.
Details under [nt round](#nt-round-2026-10-09-us-east-1-nt-1223-gb-lustre-and-s3-scenarios).

## Quick start

See [QUICKSTART.md](QUICKSTART.md) for the copy-paste version and
[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) / [DEPLOYMENT_GUIDE.ko.md](DEPLOYMENT_GUIDE.ko.md) for
details and troubleshooting.

```bash
export AWS_REGION=us-east-1 PROJECT_NAME=blast-perf-test
# 1. network (5 min)      2. EFS + staging (2-3 h for nt)      3. Lustre + S3 copy (1-2 h for nt)
# 4. query bucket + Batch (5 min)   5. ./run_tests.sh   6. ./analyze_performance.py   7. ./cleanup.sh
# To benchmark a different DB do not just change BlastDbName on the deployed stacks: delete stacks
# 04, 03, 02 (in that order) and create them again ("What was verified", #15 explains why).
```

Smoke-test the whole pipeline first with a small database
(`BlastDbName=ref_viruses_rep_genomes`, 150 MB, or `16S_ribosomal_RNA`, 20 MB) and
`LustreStorageCapacity=1200`; it costs cents and takes under an hour.

## Expected behaviour (model) and what the measurement said

Lower bounds for `nt` (1,170 GB to cache) on r6id.12xlarge, computed from published limits.
Actual `blastn` time is the larger of this storage floor and the CPU time for your query set.
The measured round ([nt round](#nt-round-2026-10-09-us-east-1-nt-1223-gb-lustre-and-s3-scenarios) below)
confirmed the S3 -> NVMe row within a factor of two and showed that the Lustre row's floor is the
wrong quantity: `blastn` reads the volumes through `mmap`, and once nt exceeds RAM the pass is bound
by random 8 KB page faults over the network, not by sequential throughput. The cold pass took
15 min on NVMe and 2 h 19 min on Lustre.

| Scenario | `db_setup` (fill layer 2) | Cold pass storage floor | Warm pass | Per cold pass storage cost |
|---|---|---|---|---|
| S3 -> NVMe | 1.2 TB download: >= ~9 min at 18.75 Gbit/s; ~13-20 min at a typical 1-1.5 GB/s `aws s3 sync` | NVMe RAID0, several GB/s: minutes | same as cold (nt > RAM) | $0 |
| EFS | 0 (pre-staged) | >= 12.4 min at the 1,500 MiB/s client cap | same as cold | ~$35 (1,170 GB x $0.03) |
| FSx for Lustre 2,400 GiB | lazy load from S3 on first touch (measured by the `vmtouch -t` hydration step) | ~6.4 min at burst (3,047 MB/s) to ~42 min at baseline (469 MB/s) | same as cold | $0 |

For a DB that fits in RAM (core_nt, 272 GB on a 384 GiB node) the warm pass is identical across
scenarios and only `db_setup` + the first cold pass differ.

## Concurrency: how the storage layer behaves when N nodes read at once

One job per scenario measures a single reader. The question that decides between a shared file
system and per-instance NVMe is what happens when several instances scan the same copy at the same
time: EFS caps each client at 1,500 MiB/s but the file system itself scales; FSx for Lustre
aggregate throughput is fixed by the provisioned size (about 470 MB/s baseline for 2,400 GiB SCRATCH_2,
however many clients read); NVMe scales linearly because every instance has its own copy, but every
new instance pays the download first.

```bash
./run_tests.sh --concurrency 4            # 4 identical jobs per queue, submitted in the same second
./analyze_performance.py --region $AWS_REGION --project $PROJECT_NAME --run <timestamp printed above>
```

`analyze_performance.py` then prints, per scenario, the job count, **p50/p95 of job wall time**
(`total_seconds`) and of the cold pass, and the **aggregate cold-pass throughput**
`MB/s = DB bytes x jobs / window`, where the window runs from the first job's cold-pass start to the
last job's cold-pass end (CloudWatch timestamps of the `db_setup` and `pass=1` METRIC lines). DB bytes
are taken from the `s3` job's `db_bytes` metric, or from `--db-gb` (default 1170, nt bytes-to-cache).
`--run <timestamp>` selects exactly the jobs of one submission via `.runs.log`.

Limits to know before raising N:

- Each job requests `JobVcpus` (48) and `JobMemoryMiB` (370,000), i.e. one whole 12xlarge, so N
  concurrent jobs mean N instances per scenario. The three compute environments are created with
  `MaxvCpus: 384`, which allows **up to 8 concurrent 48-vCPU jobs per queue** (24 with the small-DB
  variant's `JobVcpus=16`); jobs beyond that wait in `RUNNABLE`. Raise `MaxvCpus` in
  `04-batch-environment.yaml` only if you need more than 8.
- Your EC2 On-Demand vCPU quota for R instances must cover 48 x N per scenario (144 x N for all three).
- In the `s3` scenario every one of the N instances downloads its own copy of the DB, so the
  `.done` reuse never triggers inside one concurrent wave; it only pays off for later jobs landing on
  an instance that is still alive. Per-scenario cost grows linearly with N (about $3.6/h per
  instance); for EFS add $35 of reads per job and cold pass over nt.

## Small-DB variant (targeted screening)

The same four templates measure the other common case: a reference DB of tens of GB that is
scanned by many small jobs (clinical or targeted screening against `ref_prok_rep_genomes`,
`16S_ribosomal_RNA`, a custom panel). The DB fits in RAM, so pass 2 is identical everywhere and the
benchmark reduces to **staging time and cost per storage class**: how long until the first job can
start, and what one job costs on each path. Only the DB name and the instance pool change
(parameter names exactly as in the templates):

| Stack | Parameters |
|---|---|
| `02-efs-storage.yaml` | `BlastDbName=ref_prok_rep_genomes` (26.7 GB; `StagingInstanceType=m6i.large` is enough) |
| `03-lustre-storage.yaml` | `BlastDbName=ref_prok_rep_genomes` `LustreStorageCapacity=1200` |
| `04-batch-environment.yaml` | `BlastDbName=ref_prok_rep_genomes` `InstanceTypes=r6id.4xlarge,r5d.4xlarge` `JobVcpus=16` `JobMemoryMiB=120000` |

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-batch --template-file 04-batch-environment.yaml \
  --capabilities CAPABILITY_IAM --region $AWS_REGION --parameter-overrides ProjectName=$PROJECT_NAME \
  BlastDbName=ref_prok_rep_genomes InstanceTypes=r6id.4xlarge,r5d.4xlarge JobVcpus=16 JobMemoryMiB=120000 \
  QueryS3Bucket=$QUERY_BUCKET LustreFileSystemId=$LUSTRE_FS_ID LustreMountName=$LUSTRE_MOUNT
```

r6id.4xlarge / r5d.4xlarge (16 vCPU, 128 GiB, local NVMe, about $1.2 / $1.15 per hour) hold the
26.7 GB DB in the page cache with room to spare; `JobMemoryMiB=120000` stays below what the ECS agent
reports as available on a 128 GiB instance. With `MaxvCpus: 384` unchanged, `--concurrency` can go up
to 24 jobs per queue. Staging takes minutes instead of hours (EFS writes about $1.6, Lustre
hydration a few seconds), the three jobs run in well under an hour, and a complete round (deploy,
stage, three scenarios, tear down the same day) costs about **$10**, dominated by the FSx 1,200 GiB
hour-rounded charge and the NAT Gateway hours. This is the configuration in which EFS is a
legitimate contender, and the one to use to compare EFS $/job against the other two.

## Cost

List prices, us-east-1, read from the AWS Price List API on 2026-10-08. The benchmark should be run
and torn down within a day or two; the standing costs are shown per month because that is how the
services are priced, and per day because that is how long you should keep them.

| Item | Rate | For nt (1.2 TB) | Per day |
|---|---|---|---|
| EFS Standard storage | $0.30 /GB-mo | $360 /mo | $12 |
| EFS Elastic throughput writes (staging, once) | $0.06 /GB | **$72 one-time** | - |
| EFS Elastic throughput reads | $0.03 /GB | **$35 per cold pass** (rate confirmed by billing, see below) | - |
| FSx for Lustre SCRATCH_2 2,400 GiB | $0.14 /GB-mo | $336 /mo | $11 |
| S3 Standard (your DB copy) | $0.023 /GB-mo | $28 /mo | $0.9 |
| S3 copy from NCBI, same region | $0 transfer, requests negligible | $0 | - |
| S3 copy from NCBI to another region | $0.02 /GB | $24 one-time | - |
| NAT Gateway | $0.045 /h (+ $0.045/GB avoided by the S3 endpoint) | $33 /mo | $1.1 |
| Staging host m6i.4xlarge (EFS, 3-4 h) | $0.768 /h | ~$3 one-time | - |
| Copy host m6i.large (Lustre, 1-2 h) | $0.096 /h | ~$0.2 one-time | - |
| Batch r6id.12xlarge / r5d.12xlarge | $3.63 / $3.46 /h | ~1-2 h per scenario | ~$12-25 per round of 3 |

One complete round (deploy, stage, three jobs, tear down inside 24 h) is roughly **$150-200**,
of which EFS staging writes + two EFS cold passes are about $140 (running the `efs` scenario only
with `core_nt` or the small-DB variant, as recommended above, brings a round to roughly $60; the
measured `lustre` + `s3` round of 2026-10-09 came to about $30 at list price, 7 h end to end). Leaving everything up costs
about **$760 per month** plus any staging instance you forget to stop (the templates now stop them
automatically; the original r5d.24xlarge staging hosts would have cost $5,000 per month each).

### What an earlier round actually cost

A round run with the previous templates (December 2025 to February 2026, infrastructure in two
regions) was billed about **$1,680**, read from Cost Explorer by the `Name` tag:

| Item | Billed | Note |
|---|---|---|
| Two r5d.24xlarge staging hosts | ~$1,050 (62%) | one of them ran for five days straight; this is why the templates now use m6i and shut down |
| EFS storage + reads | ~$260 | one month held 2.8 TB of Elastic-throughput reads billed $85, i.e. $0.03/GB and about 2.4 cold passes over nt |
| FSx for Lustre 1,200 GiB SCRATCH_2 | ~$180 | about four weeks, including $41 of regional data transfer |
| NAT gateways (two regions) | ~$170 | hourly charge for about eight weeks; 530 GB processed in the first month before the S3 gateway endpoint existed |
| Batch compute (r6i.24xlarge) | ~$22 | |

Only the EFS read rate above is a billed figure; everything else in this section is a list-price
projection. The staging hosts cost more than the measurement itself, which is the point of
shutting them down.

## What was verified (2026-10-08)

Checked against the live NCBI bucket, AWS documentation, `cfn-lint` and `aws cloudformation validate-template`:

| # | Finding | Effect on the original templates | Fix |
|---|---|---|---|
| 1 | `s3://ncbi-blast-databases` keeps DBs as **unpacked files under a dated prefix** named in `latest-dir`; there is no `nt.*.tar.gz` and nothing at the bucket root. | EFS staging loop matched nothing and aborted on `taxdb.tar.gz`; Lustre copy's `--include "nt.*"` never matched `<prefix>/nt.*`. Both file systems would have been empty. | Resolve `latest-dir`, sync `<prefix>/nt.*`, `nt-nucl-metadata.json`, `taxdb.*`; record the prefix in `SOURCE_PREFIX`. |
| 2 | nt is **1,199 GB** (1,170 GB to cache), not 810 GB; core_nt 301 GB. | FSx 1,200 GiB would be 93 % full. | `LustreStorageCapacity` default 2,400; README numbers updated. |
| 3 | Batch `Ref::name` placeholders are only substituted when they are **separate command array elements**; `s3://Ref::QueryS3Bucket/...` inside `bash -c` is passed unchanged, and no `Parameters` defaults existed anyway. | Every job's first `aws s3 cp` failed. | Pass bucket/key/paths as container **environment variables**. |
| 4 | The `ncbi/blast` image **does not contain the AWS CLI** (it ships gcloud). | `aws s3 cp` would fail even with correct URIs. | Use NCBI's `public.ecr.aws/ncbi-elasticblast/elasticblast-elb:1.4.0` (ncbi/blast:2.17.0 + awscli + vmtouch + parallel); image is a parameter, pinned. |
| 5 | Batch `optimal` now means **m6i/c6i/r6i/c7i** (no instance store) and the default AMI is ECS-optimized AL2023. | `s3` scenario wrote 1.2 TB into the container overlay on a 30 GiB root volume; Lustre `yum install lustre-client` relied on an AL2 path. | Explicit d-type pool (`r6id.12xlarge,r5d.12xlarge`), launch template that RAID0s the NVMe to `/mnt/nvme`, `dnf install lustre-client`, same pool for all three scenarios. |
| 6 | 768,000 MiB memory per job requires a 768 GiB instance; `optimal` picked none that large. | Jobs stuck in `RUNNABLE` (`MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT`, as the original troubleshooting notes). | 48 vCPU / 370,000 MiB matched to the 12xlarge pool, parameterised. |
| 7 | FSx linked to an **empty** bucket at creation lists nothing afterwards unless `AutoImportPolicy` is set; `ImportPath: s3://bucket/nt/` maps that prefix to the file-system root, so `-db /mnt/lustre/nt/nt` pointed at a non-existent directory. | Lustre scenario would not have found the DB. | `ImportPath` = bucket root, `AutoImportPolicy: NEW_CHANGED`, DB at `/mnt/lustre/nt/nt`. |
| 8 | Staging roles lacked `ssm:PutParameter`; the "completed" signal silently failed (`|| true`). | No completion signal. | Scoped `ssm:PutParameter` on `/<project>/*`; `run_tests.sh` refuses to start until both signals read `completed`. |
| 9 | Staging/copy hosts were `r5d.24xlarge` ($6.9/h) and were never stopped; the copy is S3->S3 server-side and the EFS write is capped per client, so the size bought nothing. | Hidden cost of up to $10,000/month. | `m6i.4xlarge` / `m6i.large`, parameterised, `shutdown -h now` after staging. |
| 10 | No S3 gateway endpoint: all DB traffic crossed the NAT Gateway. | ~$54 of NAT processing per 1.2 TB pull. | Gateway endpoint added to both route tables. |
| 11 | `JobRole` had read access to the whole NCBI bucket but the `s3` job in the new design reads the in-region copy (same bytes as Lustre). | - | Least-privilege policies; `s3` job source is the in-region copy so all three scenarios read identical objects. Point `DB_SOURCE_URI` at `s3://ncbi-blast-databases/<prefix>/` to measure the cross-region variant. |
| 12 | `BLAST_USAGE_REPORT` defaults to `true` in BLAST+ and phones home usage statistics. | Not a defect, but surprising in a benchmark. | Set to `false` in every job. |

Also verified: `r6id.12xlarge`, `r5d.12xlarge`, `r6id.24xlarge`, `r5d.24xlarge` are offered in both
us-east-1 and ap-northeast-2; on-demand us-east-1 $3.6288 / $3.4560 / $7.2576 / $6.9120 per hour.

### Smoke-tested end to end (2026-10-09, ap-northeast-2, `ref_viruses_rep_genomes`, 346 MB)

The four stacks were deployed, the three scenarios run, and everything torn down again, in a region
other than us-east-1 (the us-east-1 Elastic IP quota of the test account was exhausted by other
projects' NAT gateways). Running outside the NCBI bucket's region exposed defects that static
validation could not:

| # | What happened | Cause | Fix in this repository |
|---|---|---|---|
| 13 | Lustre copy host: `CopyObject ... AccessDenied: VPC endpoints do not support cross-region requests` for every object | A server-side S3 copy whose source bucket is in another region is refused by the S3 gateway endpoint. | `03`: same region -> server-side `aws s3 sync`; other region -> each object is streamed through the host (`aws s3 cp` to stdout piped into `aws s3 cp` from stdin, 8 in parallel). 14 objects / 346 MB in 31 s. |
| 14 | After the failed copy the host kept running with no status signal (`set -e` aborted the script before `shutdown`). | No failure path. | `02`/`03`: `trap ... EXIT` always writes `completed:`/`failed:` to SSM and stops the instance. |
| 15 | A CloudFormation `UserData` change is applied as stop -> modify -> start of the **same** instance, and cloud-init runs plain user data once per instance id, so the edited script never ran. | cloud-init per-instance semantics. | `02`/`03`: user data wrapped in a cloud-init multipart with `cloud_final_modules: [scripts-user, always]`. Caveat: a **parameter-only** change (e.g. `BlastDbName`) is still re-run with the *cached* user data, so to switch databases delete and recreate stacks 02-04 (see Quick start). |
| 16 | Batch jobs: `/mnt/lustre is not a Lustre mount (fstype=xfs)`; host console: `Server MGS version (2.10.5.0) refused connection from this client with an incompatible version (2.15.6)`. | SCRATCH_2 file systems default to **Lustre 2.10**; the Amazon Linux 2023 `lustre-client` is 2.15 and cannot mount them. | `03`: `FileSystemTypeVersion: '2.15'`. An existing file system was upgraded in place (`FILE_SYSTEM_UPDATE`, 25 min, same id and mount name). |
| 17 | (latent) Lustre security group allowed only TCP 988. | LNet also needs 1018-1023 and opens connections back to clients. | `01`: 988 + 1018-1023 on the file-system SG from the client SG and itself, and on the client SG from the file-system SG. |
| 18 | `Warning: [blastn] Taxonomy name lookup from taxid requires installation of taxdb` three times per pass; `sscinames` empty. | `taxdb.*` sits next to the DB files, but BLAST looks it up through `BLASTDB`, not the `-db` path. | `04`: `export BLASTDB` set to the DB directory in all three jobs. |
| 19 | A mount failure surfaced only as `No alias or index file found`. | Jobs did not check the mount. | `04` lustre job: exit 3 if `/mnt/lustre` is not of type `lustre`, exit 4 if the DB directory is missing (prints `ls /mnt/lustre`). |
| 20 | `analyze_performance.py` printed the nt default (1,170 GB) silently when a run had no `s3` job, and the baseline ratio was inverted. | - | DB size shown with decimals and flagged `ASSUMED`; ratio is scenario / baseline, `n/a` when the baseline took 0 s. |

Measured on the smoke DB (r5d.4xlarge, `JobVcpus=16`): EFS staging 8-11 s, Lustre S3 copy 28-31 s,
S3 -> NVMe 3 s (115 MB/s through the NAT gateway, cross-region), Lustre hydration 2 s; result hash
identical across the three scenarios (51 rows). These are too small to say anything about
throughput; they show that the pipeline runs and that the three paths read the same bytes.

### nt round (2026-10-09, us-east-1, `nt`, 1,223 GB, `lustre` and `s3` scenarios)

Run in the NCBI bucket's own region once the account's Elastic IP quota had been raised, with the
`efs` scenario left out (`EnableEfsScenario=false`, see "Why three methods"). Three more defects
appeared only at this size and in this region (the third at teardown):

| # | What happened | Cause | Fix in this repository |
|---|---|---|---|
| 21 | Same-region Lustre copy host: `GetObjectTagging ... AccessDenied` for every `nt.*` volume file; the 2,686 small files (3.3 GB) copied, the database did not. Signal `failed:nt:...:43s`, host stopped itself (#14 worked). | Above the 8 MiB multipart threshold `aws s3 sync` replicates the source object's tags with `GetObjectTagging`. The copy host's role grants only `GetObject`/`ListBucket` on the NCBI bucket (#11, least privilege), so every large object failed. The cross-region path (#13) streams bytes and never calls it, which is why the smoke test in ap-northeast-2 did not show this. | `03`: `--copy-props none` on the server-side `sync` (tags and user metadata are not needed; one request per object saved). Verified on a 3 GB volume file: 17 s server-side. |
| 22 | The Batch stack could not be deployed without the EFS stack (hard `!ImportValue` of the EFS file-system id), although the README tells you to skip `efs` for nt. | - | `04`: `EnableEfsScenario` parameter (`true` default) with a `Condition` on the EFS compute environment, queue, job definition, log group and outputs. `./run_tests.sh lustre s3` then runs the two remaining scenarios. |
| 23 | Teardown: the Lustre stack ended in `DELETE_FAILED` (`The bucket you tried to delete is not empty`) with the 1.2 TB copy still in it, and the staging hosts' SSM status parameters survived every stack. `cleanup.sh` would not have helped: it derived the Lustre bucket name from an environment prefix instead of the stack, and never touched SSM. | CloudFormation does not empty buckets; the status parameters are written by user data, outside any stack. | `cleanup.sh`: reads the bucket's physical id from the stack before deleting it, empties and removes both buckets first, deletes `/<project>/efs/db-staging-status` and `/<project>/lustre/db-s3-copy-status`, then deletes the stacks. |

#### Measured (r5d.12xlarge, 48 vCPU, 384 GiB RAM, 2 x 900 GB NVMe in RAID0; FSx for Lustre SCRATCH_2 2,400 GiB, Lustre 2.15)

Query: three complete bacterial genomes (85 KB, `-task megablast` default, `-evalue 1e-3
-max_target_seqs 5`, 48 threads). DB: `nt` prefix `2026-10-06-01-05-02`, 3,557 files, 1,223 GB,
131,965,472 sequences / 4.71 x 10^12 bases. Both scenarios read the same in-region S3 copy and
produced identical results (19 rows, same hash). All times are wall-clock from the job logs.

| Step | S3 -> NVMe | FSx for Lustre | Note |
|---|---|---|---|
| S3 copy from NCBI into the account's bucket (once per DB version) | - | **1,349 s** (22.5 min, 0.91 GB/s) | Server-side `aws s3 sync`, same region, m6i.large copy host. The `s3` scenario reads the same copy. |
| `db_setup` inside the job | **2,773 s** (46.2 min, **441 MB/s**) | **3,767 s** (62.8 min, **0.33 GB/s**) | NVMe: `aws s3 sync` with `max_concurrent_requests 64`; NetworkIn was a flat 0.46 GB/s for 44 min, i.e. the CLI, not the 18.75 Gbit/s NIC, was the limit (the model above assumed 1-1.5 GB/s). Lustre: first-touch lazy load of every byte from S3 (`vmtouch -t`), bounded by the file system's S3 import rate. |
| Cold `blastn` pass | **907 s** (15.1 min) | **8,360 s** (2 h 19 min, **9.2x**) | See the two-phase profile below. |
| Second pass on the same node | **775 s** (12.9 min) | **8,374 s** (2 h 20 min) | nt (1.17 TB to cache) does not fit in 384 GiB, so the second pass is not a warm pass on either path: NVMe gains 15 %, Lustre nothing (the two passes differ by 14 s). |
| Job total (setup + 2 passes) | **4,457 s** (74 min) | **20,505 s** (5 h 42 min) | |
| Compute at list price (r5d.12xlarge $3.456/h) | **$4.3** | **$19.7** | Plus FSx 2,400 GiB for the hours it exists ($0.46/h) and the one-time copy host ($0.1). |

**Where the Lustre time goes.** FSx CloudWatch (`DataReadBytes`, `DataReadOperations`, 5-min sums)
shows the same shape in both passes: about 30 minutes of sequential reads at a steady **0.62 GB/s**
(about 600 KB per operation, roughly 1.1 TB, the word-lookup scan over the `.nsq` volumes; above the
469 MB/s SCRATCH_2 baseline, so burst credit was available), then **100 to 110 minutes of 8 KB random
reads at 5,000 to 27,000 IOPS** (70 to 215 MB/s) with the 48 vCPUs at 7 to 11 % utilisation. A
read-only look at the running process (SSM, `/proc`) during pass 1 explains the second phase:
`blastn` memory-maps the volume files and had taken 138 million major page faults; the Lustre client
caches at most `llite.max_cached_mb` = 191 GiB (50 % of RAM, default) and its extent locks age out
after `ldlm.lru_max_age` = 600 s, so the pages touched by the hydration step and by the sequential
scan are gone by the time the extension/traceback phase comes back for them, and every miss is one
network round trip for one page. The NVMe path takes the same faults, but a local NVMe serves them in
tens of microseconds at hundreds of thousands of IOPS, which is the whole 9x.

What this means for the design choice:

- For a DB that is larger than RAM, **FSx for Lustre is not a substitute for local NVMe as the
  layer `blastn` reads from.** Its value is as the shared, persistent *source* (layer 1) that
  many nodes can stage from without going back to S3; the per-node copy to NVMe (or a RAM-sized
  DB) is still needed for the search itself. With that pattern, hydration and the sequential
  phase would run at the file system's aggregate throughput, which scales with provisioned size
  (`PerUnitStorageThroughput`/capacity), while the random phase stays local.
- Mitigations on the Lustre client that we did not test here (candidates for a follow-up round,
  not recommendations): raise `llite.*.max_cached_mb` towards the free RAM, raise
  `ldlm.namespaces.*.lru_max_age`, pin the hot volumes with `vmtouch -l` when the DB (or a
  subset such as `core_nt`, 301 GB) fits in RAM, or move the random-access phase to a local copy.
- The 441 MB/s download is a CLI setting, not a hardware limit: `max_concurrent_requests` higher
  than 64, `s5cmd`, or several `sync` processes over disjoint file ranges would cut the 46-minute
  staging step; the 18.75 Gbit/s NIC allows about 2.3 GB/s.
- Pass 2 being only 15 % faster on NVMe confirms the model's "warm pass = cold pass" assumption
  for nt on a 384 GiB node. Only a bigger node (x2idn/x2iedn, 1-2 TiB RAM) or `core_nt` gets a true
  warm pass.

Evidence kept with the run: Batch job logs (`log_batch_s3.txt`, `log_batch_lustre.txt`), the copy
host log, CloudWatch 5-min series (`cw_series.tsv`), `analyze_performance.py` output, and the
`/proc` + `lctl get_param` probe of the Lustre client (`lustre_cache_probe.txt`). Billed cost of the
round: to be read from Cost Explorer once the day has closed; list-price estimate about **$30**
(Batch ~$25, FSx ~$3.5, NAT/S3/EIP under $1), EFS scenario excluded.

## Project structure

```
.
├── 01-network-infrastructure.yaml   VPC, subnets, NAT, S3 gateway endpoint, security groups
├── 02-efs-storage.yaml              EFS + staging host (BlastDbName, StagingInstanceType)
├── 03-lustre-storage.yaml           S3 bucket + FSx for Lustre + S3->S3 copy host (LustreStorageCapacity)
├── 04-batch-environment.yaml        3 compute environments / queues / job definitions (InstanceTypes, JobVcpus, ...)
├── run_tests.sh                     submit one job per scenario, or N with --concurrency N (checks staging status first)
├── analyze_performance.py           parse METRIC lines -> comparison table, p50/p95 + aggregate MB/s, JSON
├── cleanup.sh                       delete everything in reverse order
├── DEPLOYMENT_GUIDE.md / .ko.md     step-by-step guide and troubleshooting (English / Korean)
└── QUICKSTART.md
```

## Requirements

- AWS CLI v2, an account with CloudFormation/EC2/EFS/FSx/Batch/IAM permissions
- EC2 On-Demand vCPU quota for R instances >= 48 per concurrent job (144 to run all three scenarios at once, x N with `--concurrency N`)
- A query FASTA uploaded to `s3://<query-bucket>/queries/query.fasta`
- Python 3 + boto3 for `analyze_performance.py`

## References

- [NCBI BLAST DBs on AWS Open Data](https://registry.opendata.aws/ncbi-blast-databases/) and
  [BLAST+ Docker docs](https://github.com/ncbi/blast_plus_docs) (`update_blastdb.pl --showall --source aws`)
- [ElasticBLAST](https://github.com/ncbi/elastic-blast) and [Camacho et al. 2023](https://pmc.ncbi.nlm.nih.gov/articles/PMC10040096/)
- [AWS Batch job definition parameters](https://docs.aws.amazon.com/batch/latest/userguide/job_definition_parameters.html) (Ref:: substitution rules),
  [`optimal` instance type update](https://docs.aws.amazon.com/batch/latest/userguide/optimal-default-instance-troubleshooting.html)
- [EFS quotas (per-client throughput)](https://docs.aws.amazon.com/efs/latest/ug/limits.html),
  [FSx for Lustre performance](https://docs.aws.amazon.com/fsx/latest/LustreGuide/ssd-storage.html),
  [FSx auto-import](https://docs.aws.amazon.com/fsx/latest/LustreGuide/autoimport-data-repo.html),
  [Lustre client install](https://docs.aws.amazon.com/fsx/latest/LustreGuide/install-lustre-client.html)

## License

MIT License - see [LICENSE](LICENSE).
