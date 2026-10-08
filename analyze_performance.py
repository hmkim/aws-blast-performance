#!/usr/bin/env python3
"""Collect METRIC lines written by the Batch jobs and print a per-scenario comparison.

Each job logs lines such as
    METRIC scenario=efs job=...
    METRIC instance_type=r6id.12xlarge
    METRIC db_setup_seconds=0 (pre-staged)
    METRIC pass=1 blast_seconds=1234 rows=5678 sha256=abcd...
    METRIC pass=2 blast_seconds=456 rows=5678 sha256=abcd...
    METRIC total_seconds=2000
One CloudWatch log stream == one job attempt.

Usage: ./analyze_performance.py [--region us-east-1] [--project blast-perf-test] [--run 20260108-1200] [--json out.json]
"""
import argparse
import json
import re
import sys
from collections import defaultdict

import boto3

SCENARIOS = ("efs", "lustre", "s3")
KV = re.compile(r"(\w+)=(\S+)")


def collect(logs, group, run_filter=None):
    """Return {stream: {metric dict}} for every stream in the log group."""
    out = {}
    paginator = logs.get_paginator("filter_log_events")
    try:
        pages = paginator.paginate(logGroupName=group, filterPattern="METRIC")
        for page in pages:
            for ev in page["events"]:
                m = out.setdefault(ev["logStreamName"], {"passes": {}, "first_ts": ev["timestamp"]})
                kv = dict(KV.findall(ev["message"]))
                if "pass" in kv:
                    m["passes"][int(kv["pass"])] = {
                        "blast_seconds": int(kv.get("blast_seconds", 0)),
                        "rows": int(kv.get("rows", 0)),
                        "sha256": kv.get("sha256"),
                    }
                else:
                    m.update({k: v for k, v in kv.items() if k != "pass"})
    except logs.exceptions.ResourceNotFoundException:
        pass
    if run_filter:
        out = {k: v for k, v in out.items() if run_filter in k or run_filter in json.dumps(v)}
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--region", default="us-east-1")
    ap.add_argument("--project", default="blast-perf-test")
    ap.add_argument("--run", default=None, help="only streams whose name or metrics contain this string")
    ap.add_argument("--json", default=None, help="write raw metrics to this file")
    ap.add_argument("positional_region", nargs="?", help=argparse.SUPPRESS)  # backwards compat: ./analyze_performance.py us-east-1
    a = ap.parse_args()
    region = a.positional_region or a.region

    logs = boto3.client("logs", region_name=region)
    results = {}
    for s in SCENARIOS:
        results[s] = collect(logs, f"/{a.project}/batch/{s}", a.run)

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
