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
| **EFS** | "Simplest shared POSIX file system": no capacity planning, multi-AZ, mounted by ECS natively. | Whether a single NFS client's cap (1,500 MiB/s with efs-utils 2.x) and the Elastic-throughput read charge are acceptable for a streaming scan of the DB. | $0.03/GB read means every cold pass over nt costs about **$35** in EFS reads alone; the per-client cap puts a floor of ~12.4 min under a full 1,170 GB scan. Fits small DBs (tens of GB) that then live in RAM. |
| **FSx for Lustre** | "Shared parallel file system for many concurrent nodes": HPC standard, S3-linked, no per-read charge, throughput scales with provisioned size. | Hydration time from S3 on first touch, then steady-state read throughput against many clients; whether 2,400 GiB SCRATCH_2 (about 470 MB/s baseline, bursts to about 3 GB/s) keeps up with a 48-thread blastn. | Single AZ; billed hourly for provisioned capacity whether used or not; a 1,200 GiB file system would be 93 % full with nt and too slow (234 MB/s baseline). |

Which one wins depends on how many jobs share one copy of the database before it is thrown away:
a daily cadence of thousands of jobs over `nt` favours a shared file system; a few large batch
searches a month favour per-instance NVMe (or ElasticBLAST). This repository exists to put numbers on
that trade-off instead of guessing.

## Quick start

See [QUICKSTART.md](QUICKSTART.md) for the copy-paste version and
[DEPLOYMENT_GUIDE.md](DEPLOYMENT_GUIDE.md) / [DEPLOYMENT_GUIDE.ko.md](DEPLOYMENT_GUIDE.ko.md) for
details and troubleshooting.

```bash
export AWS_REGION=us-east-1 PROJECT_NAME=blast-perf-test
# 1. network (5 min)      2. EFS + staging (2-3 h for nt)      3. Lustre + S3 copy (1-2 h for nt)
# 4. query bucket + Batch (5 min)   5. ./run_tests.sh   6. ./analyze_performance.py   7. ./cleanup.sh
```

Smoke-test the whole pipeline first with a small database
(`BlastDbName=ref_viruses_rep_genomes`, 150 MB, or `16S_ribosomal_RNA`, 20 MB) and
`LustreStorageCapacity=1200`; it costs cents and takes under an hour.

## Expected behaviour (model, to be replaced by measurements)

Lower bounds for `nt` (1,170 GB to cache) on r6id.12xlarge, computed from published limits.
Actual `blastn` time is the larger of this storage floor and the CPU time for your query set.

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
of which EFS staging writes + two EFS cold passes are about $140. Leaving everything up costs
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
