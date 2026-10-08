#!/usr/bin/env python3
"""Collect METRIC lines written by the Batch jobs and print a per-scenario comparison.

Each job logs lines such as
    METRIC scenario=efs job=...
    METRIC instance_type=r6id.12xlarge
    METRIC db_setup_seconds=0 (pre-staged)              (s3 scenario adds db_bytes=... mbps=...)
    METRIC pass=1 blast_seconds=1234 rows=5678 sha256=abcd...
    METRIC pass=2 blast_seconds=456 rows=5678 sha256=abcd...
    METRIC total_seconds=2000
One CloudWatch log stream == one job attempt.

When several jobs per scenario ran at once (`run_tests.sh --concurrency N`) the summary adds, per
scenario: job count, p50/p95 of job wall time (total_seconds) and of the cold pass, and the
aggregate cold-pass throughput  MB/s = DB bytes x jobs / window,  where the window runs from the
first job's cold-pass start to the last job's cold-pass end (CloudWatch event timestamps of the
db_setup and pass=1 METRIC lines). DB bytes come from the s3 scenario's db_bytes metric when
present, otherwise from --db-gb (default 1170 = nt bytes-to-cache, 2026-09).

Usage: ./analyze_performance.py [--region us-east-1] [--project blast-perf-test] [--run 20260108-120000]
                                [--db-gb 1170] [--json out.json]
--run accepts the timestamp printed by run_tests.sh: the job ids are looked up in .runs.log, so only
that run's streams are analysed (falls back to a substring match on stream names/metrics).
"""
import argparse
import json
import os
import re
import sys
from collections import defaultdict

import boto3

SCENARIOS = ("efs", "lustre", "s3")
KV = re.compile(r"(\w+)=(\S+)")
RUNS_LOG = ".runs.log"


def collect(logs, group, run_filter=None, job_ids=None):
    """Return {stream: {metric dict}} for every stream in the log group."""
    out = {}
    paginator = logs.get_paginator("filter_log_events")
    try:
        pages = paginator.paginate(logGroupName=group, filterPattern="METRIC")
        for page in pages:
            for ev in page["events"]:
                m = out.setdefault(ev["logStreamName"], {"passes": {}, "ts": {}, "first_ts": ev["timestamp"]})
                m["last_ts"] = ev["timestamp"]
                kv = dict(KV.findall(ev["message"]))
                if "pass" in kv:
                    p = int(kv["pass"])
                    m["passes"][p] = {
                        "blast_seconds": int(kv.get("blast_seconds", 0)),
                        "rows": int(kv.get("rows", 0)),
                        "sha256": kv.get("sha256"),
                    }
                    m["ts"][f"pass{p}_end"] = ev["timestamp"]
                else:
                    if "db_setup_seconds" in kv:
                        m["ts"]["setup_end"] = ev["timestamp"]
                    m.update({k: v for k, v in kv.items() if k != "pass"})
    except logs.exceptions.ResourceNotFoundException:
        pass
    if job_ids:
        out = {k: v for k, v in out.items() if v.get("job") in job_ids}
    elif run_filter:
        out = {k: v for k, v in out.items() if run_filter in k or run_filter in json.dumps(v)}
    return out


def job_ids_for_run(run):
    """Job ids recorded by run_tests.sh for this run timestamp, or None if unknown."""
    if not run or not os.path.exists(RUNS_LOG):
        return None
    with open(RUNS_LOG) as f:
        for line in f:
            parts = line.split()
            if parts and parts[0] == run:
                ids = parts[1:]
                if ids and ids[0].isdigit():  # newer format: <timestamp> <concurrency> <ids...>
                    ids = ids[1:]
                return set(ids)
    return None


def percentile(values, pct):
    """Nearest-rank percentile; fine for the handful of jobs a benchmark run produces."""
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(pct / 100.0 * len(s) + 0.5)) - 1))
    return s[k]


def fmt(v, suffix=""):
    return "?" if v is None else f"{v}{suffix}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument("--project", default="blast-perf-test")
    ap.add_argument("--run", default=None, help="run timestamp from run_tests.sh (looked up in .runs.log) or a substring")
    ap.add_argument("--db-gb", type=float, default=1170.0,
                    help="DB bytes read per cold pass, in GB, when no job reported db_bytes (default: nt bytes-to-cache)")
    ap.add_argument("--json", default=None, help="write raw metrics to this file")
    ap.add_argument("positional_region", nargs="?", help=argparse.SUPPRESS)  # backwards compat: ./analyze_performance.py us-east-1
    a = ap.parse_args()
    region = a.positional_region or a.region

    job_ids = job_ids_for_run(a.run)
    if a.run and job_ids:
        print(f"run {a.run}: {len(job_ids)} job(s) from {RUNS_LOG}")

    logs = boto3.client("logs", region_name=region)
    results = {}
    for s in SCENARIOS:
        results[s] = collect(logs, f"/{a.project}/batch/{s}", a.run, job_ids)

    print(f"\n{'scenario':<8} {'instance':<16} {'db_setup_s':>10} {'pass1_s':>8} {'pass2_s':>8} {'rows':>8} {'sha256':<16} {'total_s':>8}  stream")
    print("-" * 110)
    summary = defaultdict(list)
    for s in SCENARIOS:
        for stream, m in sorted(results[s].items(), key=lambda kv: kv[1].get("first_ts", 0)):
            p1 = m["passes"].get(1, {})
            p2 = m["passes"].get(2, {})
            print(f"{s:<8} {m.get('instance_type', '?'):<16} {m.get('db_setup_seconds', '?'):>10} "
                  f"{p1.get('blast_seconds', '?'):>8} {p2.get('blast_seconds', '?'):>8} {p1.get('rows', '?'):>8} "
                  f"{(p1.get('sha256') or '?'):<16} {m.get('total_seconds', '?'):>8}  {stream}")
            if p1:
                summary[s].append((int(m.get("db_setup_seconds", 0) or 0), p1["blast_seconds"], p2.get("blast_seconds"), p1.get("sha256")))

    # Result identity check: every scenario must produce the same sorted output hash for the same query/DB.
    hashes = {h for v in summary.values() for *_, h in v if h}
    print("\nresult hash identical across all runs:", "yes" if len(hashes) == 1 else f"NO ({len(hashes)} distinct)")

    # Concurrency view: distribution of job times and aggregate cold-pass throughput per scenario.
    db_bytes = None
    for m in results["s3"].values():
        if str(m.get("db_bytes", "")).isdigit():
            db_bytes = int(m["db_bytes"])
    if db_bytes is None:
        db_bytes = int(a.db_gb * 1e9)
    print(f"\nconcurrency (DB bytes per cold pass = {db_bytes / 1e9:,.0f} GB)")
    print(f"{'scenario':<8} {'jobs':>4} {'wall_p50_s':>10} {'wall_p95_s':>10} {'cold_p50_s':>10} {'cold_p95_s':>10} {'window_s':>8} {'aggregate_MB/s':>14}")
    for s in SCENARIOS:
        jobs = [m for m in results[s].values() if 1 in m["passes"]]
        if not jobs:
            continue
        walls = [int(m["total_seconds"]) for m in jobs if str(m.get("total_seconds", "")).isdigit()]
        colds = [m["passes"][1]["blast_seconds"] for m in jobs]
        starts = [m["ts"]["setup_end"] for m in jobs if "setup_end" in m["ts"]]
        ends = [m["ts"]["pass1_end"] for m in jobs if "pass1_end" in m["ts"]]
        window = (max(ends) - min(starts)) / 1000.0 if starts and ends else None
        agg = db_bytes * len(jobs) / window / 1e6 if window and window > 0 else None
        print(f"{s:<8} {len(jobs):>4} {fmt(percentile(walls, 50)):>10} {fmt(percentile(walls, 95)):>10} "
              f"{fmt(percentile(colds, 50)):>10} {fmt(percentile(colds, 95)):>10} "
              f"{(f'{window:.0f}' if window else '?'):>8} {(f'{agg:,.0f}' if agg else '?'):>14}")

    base = summary.get("s3")
    if base:
        b_setup, b_p1, *_ = base[-1]
        print(f"\nBaseline (S3 -> NVMe, latest run): db_setup {b_setup}s + cold pass {b_p1}s = {b_setup + b_p1}s")
        for s in ("efs", "lustre"):
            if summary.get(s):
                setup, p1, p2, _ = summary[s][-1]
                print(f"  {s:<6}: db_setup {setup}s + cold pass {p1}s = {setup + p1}s "
                      f"({(b_setup + b_p1) / max(setup + p1, 1):.2f}x of baseline time)"
                      + (f", warm pass {p2}s" if p2 else ""))

    if a.json:
        with open(a.json, "w") as f:
            json.dump(results, f, indent=1, default=str)
        print(f"\nraw metrics written to {a.json}")
    if not any(results.values()):
        print("no METRIC lines found - have the jobs finished? (aws batch describe-jobs ...)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
