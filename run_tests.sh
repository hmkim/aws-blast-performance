#!/bin/bash
# Submit BLAST jobs per storage scenario (or only the scenarios given as arguments).
#   ./run_tests.sh                      # efs lustre s3, one job each
#   ./run_tests.sh lustre s3            # subset
#   ./run_tests.sh --concurrency 4      # 4 jobs per queue submitted at once (shared-storage contention test)
#
# With --concurrency N every queue receives N identical jobs in the same second. Each job asks for
# JobVcpus (48 by default), so N jobs need N instances; MaxvCpus=384 in 04-batch-environment.yaml
# allows up to 8 concurrent 48-vCPU jobs per queue (24 with JobVcpus=16). Your EC2 On-Demand vCPU
# quota for R instances must also cover 48 x N per scenario.
set -euo pipefail

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

PROJECT_NAME="${PROJECT_NAME:-blast-perf-test}"
REGION="${REGION:-${AWS_REGION:-us-east-1}}"
CONCURRENCY=1
SCENARIOS=()
while [ $# -gt 0 ]; do
  case $1 in
    -h|--help) usage 0 ;;
    -c|--concurrency) [ $# -ge 2 ] || { echo "--concurrency needs a value" >&2; usage 1; }; CONCURRENCY=$2; shift 2 ;;
    --concurrency=*) CONCURRENCY=${1#*=}; shift ;;
    -*) echo "unknown option: $1" >&2; usage 1 ;;
    *) SCENARIOS+=("$1"); shift ;;
  esac
done
[[ $CONCURRENCY =~ ^[1-9][0-9]*$ ]] || { echo "--concurrency must be a positive integer, got '$CONCURRENCY'" >&2; exit 1; }
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(efs lustre s3)

echo "=========================================="
echo "BLAST Storage Performance Test"
echo "project=$PROJECT_NAME region=$REGION scenarios=${SCENARIOS[*]} concurrency=$CONCURRENCY"
echo "=========================================="

stack_output() {
  aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-batch" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# Refuse to run before the DBs are staged (both stacks write an SSM parameter when done).
# The parameter outlives its stack, so the DB name inside the signal must match the Batch
# stack's BlastDbName -- a stale "completed:<other db>" from an earlier deployment does not count.
staging_status() {
  aws ssm get-parameter --name "$1" --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "missing"
}
EXPECTED_DB=$(aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-batch" --region "$REGION" \
  --query "Stacks[0].Parameters[?ParameterKey=='BlastDbName'].ParameterValue" --output text)
for s in "${SCENARIOS[@]}"; do
  case $s in
    efs)    st=$(staging_status "/${PROJECT_NAME}/efs/db-staging-status") ;;
    lustre|s3) st=$(staging_status "/${PROJECT_NAME}/lustre/db-s3-copy-status") ;;
    *) echo "unknown scenario: $s" >&2; exit 1 ;;
  esac
  echo "staging status for $s: $st (batch stack expects DB '$EXPECTED_DB')"
  case $st in "completed:${EXPECTED_DB}:"*) ;; *) echo "DB '$EXPECTED_DB' for scenario '$s' is not staged yet (signal: $st) - aborting" >&2; exit 1 ;; esac
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
JOB_IDS=()
for s in "${SCENARIOS[@]}"; do
  case $s in
    efs)    Q=$(stack_output JobQueueEFSArn);    D=$(stack_output JobDefinitionEFS) ;;
    lustre) Q=$(stack_output JobQueueLustreArn); D=$(stack_output JobDefinitionLustre) ;;
    s3)     Q=$(stack_output JobQueueS3Arn);     D=$(stack_output JobDefinitionS3) ;;
  esac
  for ((i = 1; i <= CONCURRENCY; i++)); do
    NAME="blast-${s}-${TIMESTAMP}"
    [ "$CONCURRENCY" -gt 1 ] && NAME="${NAME}-$(printf '%02d' "$i")"
    ID=$(aws batch submit-job \
      --job-name "$NAME" \
      --job-queue "$Q" --job-definition "$D" \
      --tags "project=${PROJECT_NAME},scenario=${s},run=${TIMESTAMP},concurrency=${CONCURRENCY}" \
      --region "$REGION" --query 'jobId' --output text)
    JOB_IDS+=("$ID")
    echo "submitted $NAME -> $ID"
  done
  echo "  logs: aws logs tail /${PROJECT_NAME}/batch/${s} --follow --region $REGION"
done

echo
echo "Status:  aws batch describe-jobs --jobs ${JOB_IDS[*]} --region $REGION --query 'jobs[].{name:jobName,status:status,reason:statusReason}' --output table"
echo "Analyze: ./analyze_performance.py --region $REGION --project $PROJECT_NAME --run $TIMESTAMP"
# One line per run: <timestamp> <concurrency> <job ids...>; analyze_performance.py --run reads it.
echo "$TIMESTAMP $CONCURRENCY ${JOB_IDS[*]}" >> .runs.log
