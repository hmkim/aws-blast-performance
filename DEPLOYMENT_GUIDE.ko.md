# BLAST 스토리지 성능 비교 인프라 배포 가이드

## 개요

3가지 스토리지 시나리오에서 BLAST 성능을 비교하는 AWS 인프라 배포 및 문제 해결 가이드

## 배포된 리소스

### 네트워크 (VPC)
- VPC: 10.0.0.0/16
- Public Subnets: 2개 (가용영역 a, b)
- Private Subnets: 2개 (가용영역 a, b)
- NAT Gateway: 1개
- Internet Gateway: 1개

### 스토리지
- **EFS**: 810 GB NT 데이터베이스
- **FSx for Lustre**: 1200 GB NT 데이터베이스
- **S3**: 쿼리 파일 및 Lustre 백업

### AWS Batch
- Job Queues: 3개 (EFS, Lustre, S3)
- Compute Environments: 3개 (각 384 vCPU)
- Job Definitions: 3개 (32 vCPU, 768 GB 메모리)

## 배포 순서

### 1단계: 네트워크 인프라

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

### 2단계: EFS 스토리지 및 NT DB 업로드

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

# NT DB 다운로드 진행 상황 모니터링 (약 2-3시간)
aws logs tail /blast-perf-test/efs/nt-download --follow --region <YOUR_REGION>
```

### 3단계: Lustre 스토리지 및 S3 복사

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

# S3 복사 진행 상황 모니터링 (약 2-3시간)
aws logs tail /blast-perf-test/lustre/nt-s3-copy --follow --region <YOUR_REGION>
```

### 4단계: AWS Batch 환경

#### 4-1. 쿼리 파일 업로드

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
QUERY_BUCKET="blast-perf-test-queries-${ACCOUNT_ID}"

aws s3 mb s3://$QUERY_BUCKET --region <YOUR_REGION>
aws s3 cp ../data/query.fasta s3://$QUERY_BUCKET/queries/query.fasta
```

#### 4-2. Batch 스택 배포

**중요**: 04-batch-environment.yaml 수정 필요

1. **Lustre 마운트 명령어 수정**:
```yaml
# 잘못된 예:
mount -t lustre ${LustreFileSystem.DNSName}@tcp:/fsx /mnt/lustre

# 올바른 예:
mount -t lustre ${LustreFileSystemId}.fsx.${AWS::Region}.amazonaws.com@tcp:/${LustreMountName} /mnt/lustre
```

2. **Parameters 섹션에 추가**:
```yaml
Parameters:
  LustreFileSystemId:
    Type: String
    Description: FSx for Lustre file system ID

  LustreMountName:
    Type: String
    Description: FSx for Lustre mount name
```

3. **인스턴스 타입을 optimal로 설정** (용량 문제 해결):
```yaml
ComputeResources:
  InstanceTypes:
    - optimal  # 특정 인스턴스 타입 대신 optimal 사용
```

#### 4-3. 배포 실행

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

## BLAST 작업 실행

### 자동 실행 (권장)

```bash
./run_tests.sh
```

### 수동 실행

#### EFS 시나리오
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

#### Lustre 시나리오
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

#### S3 시나리오
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

## 모니터링

### 작업 상태 확인
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

## 문제 해결

### 1. Batch 작업이 RUNNABLE 상태에서 멈춤

**증상**: 
```
MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT - The job resource requirement (vCPU/memory/GPU) 
is higher than that can be met by the CE(s) attached to the job queue.
```

**원인**: 
- 특정 인스턴스 타입의 리전 용량 부족
- Job Definition의 vCPU 요구사항이 너무 높음

**해결책**:

1. **인스턴스 타입을 optimal로 변경** (권장):
```yaml
ComputeResources:
  InstanceTypes:
    - optimal
```

2. **vCPU 요구사항 줄이기**:
```yaml
# Job Definition에서
Vcpus: 32  # 96 → 48 → 32로 단계적 감소
```

3. **여러 인스턴스 타입 추가**:
```yaml
InstanceTypes:
  - r5.8xlarge
  - r5d.8xlarge
  - r5.12xlarge
  - r5d.12xlarge
```

4. **SPOT 인스턴스 사용**:
```yaml
ComputeResources:
  Type: SPOT
  BidPercentage: 100
```

### 2. Lustre 마운트 실패

**증상**: Job이 시작되지만 Lustre 마운트 실패

**해결책**: 
- 04-batch-environment.yaml에서 Lustre 마운트 명령어 수정
- Parameters에 LustreFileSystemId, LustreMountName 추가

### 3. EC2 인스턴스가 시작되지 않음

**확인 사항**:
```bash
# Compute Environment 상태
aws batch describe-compute-environments \
  --region <YOUR_REGION> \
  --query 'computeEnvironments[*].{Name:computeEnvironmentName,Status:status,DesiredvCpus:computeResources.desiredvCpus}'

# 인스턴스 타입 가용성
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters Name=instance-type,Values=r5.12xlarge \
  --region <YOUR_REGION>
```

**해결책**:
- 다른 리전 사용 (us-east-1, us-west-2)
- SPOT 인스턴스 사용
- optimal 인스턴스 타입 사용

### 4. Job Queue가 이전 Compute Environment 참조

**확인**:
```bash
aws batch describe-job-queues \
  --job-queues <QUEUE_NAME> \
  --region <YOUR_REGION> \
  --query 'jobQueues[0].computeEnvironmentOrder[*].computeEnvironment'
```

**해결책**: 
- 기존 작업 취소 후 재제출
- CloudFormation 스택 업데이트 완료 대기

## 리소스 정리

```bash
# 역순으로 삭제
aws cloudformation delete-stack --stack-name blast-perf-test-batch --region <YOUR_REGION>
aws cloudformation delete-stack --stack-name blast-perf-test-lustre --region <YOUR_REGION>
aws cloudformation delete-stack --stack-name blast-perf-test-efs --region <YOUR_REGION>
aws cloudformation delete-stack --stack-name blast-perf-test-network --region <YOUR_REGION>

# S3 버킷 삭제
aws s3 rb s3://$QUERY_BUCKET --force --region <YOUR_REGION>
aws s3 rb s3://blast-nt-lustre-<REGION>-${ACCOUNT_ID} --force --region <YOUR_REGION>
```

## 비용 최적화 팁

1. **SPOT 인스턴스 사용**: 최대 90% 비용 절감
2. **작업 완료 후 즉시 리소스 삭제**
3. **EFS/Lustre는 사용하지 않을 때 삭제**
4. **NAT Gateway 비용 주의**: 시간당 과금

## 성능 예상

| 시나리오 | DB 로드 시간 | BLAST 실행 시간 | 총 시간 |
|---------|------------|---------------|--------|
| EFS | 0초 | 15-20분 | 15-20분 |
| Lustre | 0초 | 10-15분 | 10-15분 |
| S3 | 30-60분 | 10-15분 | 40-75분 |

## 주요 교훈

1. **리전 용량 확인**: 배포 전 인스턴스 타입 가용성 확인
2. **optimal 인스턴스 타입 사용**: 특정 타입 지정보다 유연함
3. **단계적 vCPU 감소**: 96 → 48 → 32로 조정
4. **CloudFormation 파라미터 검증**: Lustre 관련 파라미터 누락 주의
5. **작업 재제출 전 스택 업데이트 완료 대기**: 이전 Compute Environment 참조 방지

## 참고 자료

- [AWS Batch 문서](https://docs.aws.amazon.com/batch/)
- [Amazon EFS 성능](https://docs.aws.amazon.com/efs/latest/ug/performance.html)
- [FSx for Lustre 성능](https://docs.aws.amazon.com/fsx/latest/LustreGuide/performance.html)
- [NCBI BLAST 문서](https://blast.ncbi.nlm.nih.gov/doc/blast-help/)
