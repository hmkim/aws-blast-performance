#!/bin/bash
# Submit one BLAST job per storage scenario (or only the scenarios given as arguments).
#   ./run_tests.sh              # efs lustre s3
#   ./run_tests.sh lustre s3    # subset
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-blast-perf-test}"
REGION="${REGION:-${AWS_REGION:-us-east-1}}"
SCENARIOS=("$@")
[ ${#SCENARIOS[@]} -eq 0 ] && SCENARIOS=(efs lustre s3)

echo "=========================================="
echo "BLAST Storage Performance Test"
echo "project=$PROJECT_NAME region=$REGION scenarios=${SCENARIOS[*]}"
echo "=========================================="

stack_output() {
  aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-batch" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}

# Refuse to run before the DBs are staged (both stacks write an SSM parameter when done).
staging_status() {
  aws ssm get-parameter --name "$1" --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || echo "missing"
}
for s in "${SCENARIOS[@]}"; do
  case $s in
    efs)    st=$(staging_status "/${PROJECT_NAME}/efs/db-staging-status") ;;
    lustre|s3) st=$(staging_status "/${PROJECT_NAME}/lustre/db-s3-copy-status") ;;
    *) echo "unknown scenario: $s" >&2; exit 1 ;;
  esac
  echo "staging status for $s: $st"
  case $st in completed*) ;; *) echo "DB for scenario '$s' is not staged yet - aborting" >&2; exit 1 ;; esac
done

TIMESTAMP=$(date +%Y%m%d-%H%M%S)
declare -A JOB_IDS
for s in "${SCENARIOS[@]}"; do
  case $s in
    efs)    Q=$(stack_output JobQueueEFSArn);    D=$(stack_output JobDefinitionEFS) ;;
    lustre) Q=$(stack_output JobQueueLustreArn); D=$(stack_output JobDefinitionLustre) ;;
    s3)     Q=$(stack_output JobQueueS3Arn);     D=$(stack_output JobDefinitionS3) ;;
  esac
  JOB_IDS[$s]=$(aws batch submit-job \
    --job-name "blast-${s}-${TIMESTAMP}" \
    --job-queue "$Q" --job-definition "$D" \
    --tags "project=${PROJECT_NAME},scenario=${s},run=${TIMESTAMP}" \
    --region "$REGION" --query 'jobId' --output text)
  echo "submitted $s -> ${JOB_IDS[$s]}   logs: aws logs tail /${PROJECT_NAME}/batch/${s} --follow --region $REGION"
done

echo
echo "Status:  aws batch describe-jobs --jobs ${JOB_IDS[*]} --region $REGION --query 'jobs[].{name:jobName,status:status,reason:statusReason}' --output table"
echo "Analyze: ./analyze_performance.py --region $REGION --project $PROJECT_NAME --run $TIMESTAMP"
echo "$TIMESTAMP ${JOB_IDS[*]}" >> .runs.log
