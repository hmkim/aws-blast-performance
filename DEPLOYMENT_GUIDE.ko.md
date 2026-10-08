# BLAST 스토리지 성능 비교 벤치마크 - 배포 가이드

[README.md](README.md)(아키텍처·세 방식의 필요성·검증 사항)와 [QUICKSTART.md](QUICKSTART.md)(복사-붙여넣기 명령)의 보조 문서. 각 스택이 무엇을 만들고, 어떤 파라미터가 결과를 좌우하며, 결과를 어떻게 읽고, 실제로 발생하는 장애를 어떻게 복구하는지 설명한다.

## 배포되는 것

| 스택 | 리소스 | 중요한 파라미터 |
|---|---|---|
| `<project>-network` | VPC 10.0.0.0/16, 퍼블릭 2 + 프라이빗 2 서브넷(AZ a/b), IGW, NAT GW, **S3 게이트웨이 엔드포인트**, 보안 그룹(Batch; EFS 2049는 Batch에서만; Lustre 988은 Batch와 자기 자신에서만) | `ProjectName` |
| `<project>-efs` | EFS(암호화, generalPurpose, **Elastic** 처리량) + 마운트 타깃 2; 스테이징 EC2 호스트가 NCBI 최신 접두어에서 `<db>.*`, `<db>-nucl-metadata.json`, `taxdb.*`를 `/mnt/efs/<db>/`로 sync -> SSM 파라미터 `/<project>/efs/db-staging-status` 기록 -> 자동 정지 | `BlastDbName`(nt), `StagingInstanceType`(m6i.4xlarge) |
| `<project>-lustre` | S3 버킷 `<S3BucketName>-<account>`; 그 버킷에 연결된 FSx for Lustre SCRATCH_2(`AutoImportPolicy: NEW_CHANGED`); 복사 EC2 호스트가 NCBI -> `s3://bucket/<db>/`로 서버 측 `aws s3 sync` -> `/<project>/lustre/db-s3-copy-status` 기록 -> 자동 정지 | `BlastDbName`, `LustreStorageCapacity`(nt는 2400), `S3BucketName` |
| `<project>-batch` | 관리형 컴퓨팅 환경 3개(동일 인스턴스 풀, 최소 0 vCPU), 잡 큐 3, 잡 정의 3, 런치 템플릿(Lustre 마운트 / NVMe RAID0), 잡 역할, 로그 그룹 `/<project>/batch/{efs,lustre,s3}` | `BlastDbName`, `QueryS3Bucket`, `LustreFileSystemId`, `LustreMountName`, `InstanceTypes`, `JobVcpus`, `JobMemoryMiB`, `BlastPasses`, `BlastImage` |

DB 이름은 세 스택에서 같아야 한다. Batch 잡 정의는 `-db /mnt/<layer>/<db>/<db>`를 이 값에서 만든다.

## DB와 인스턴스 풀 선택

| DB (2026-09 스냅샷) | 크기 | 캐시 필요 바이트 | RAM에 들어가는 인스턴스 | 용도 |
|---|---|---|---|---|
| `nt` | 1,199 GB, 390 볼륨 | 1,170 GB | R 계열 없음(최대 768 GiB) | 스토리지 바운드 벤치마크: 모든 패스에서 스토리지 계층이 병목 |
| `core_nt` | 301 GB, 91 볼륨 | 272 GB | r6id/r5d.12xlarge(384 GiB) | "한 번 캐시되면 스토리지는 무관" 영역 확인: 2회차 패스는 RAM에서 실행 |
| `ref_prok_rep_genomes` | 26.7 GB | - | 모두 | 타깃 DB 올리고 스크리닝형 워크로드 대표 |
| `ref_viruses_rep_genomes`, `16S_ribosomal_RNA` | 150 MB, 20 MB | - | 모두 | 파이프라인 스모크 테스트 |

기본 풀 `r6id.12xlarge,r5d.12xlarge`(48 vCPU, 384 GiB, NVMe 2장 1,425 GB / 900 GB)는 nt를 인스턴스 스토어에 담을 수 있는 가장 작은 d형이다. 세 시나리오의 풀은 반드시 동일하게 둔다. CPU나 RAM이 달라지면 비교가 무효다. `JobMemoryMiB`는 ECS 에이전트가 등록하는 값보다 작아야 한다(384 GiB 설치 -> 약 386,000 MiB 사용 가능).

## 단계별 배포

### 1. 네트워크

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-network \
  --template-file 01-network-infrastructure.yaml \
  --parameter-overrides ProjectName=$PROJECT_NAME --region $AWS_REGION
```

### 2. EFS와 스테이징

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-efs \
  --template-file 02-efs-storage.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ProjectName=$PROJECT_NAME BlastDbName=$BLAST_DB --region $AWS_REGION
```

스택은 호스트가 running이 되면 `CREATE_COMPLETE`가 되고, 복사는 백그라운드로 계속된다. `aws logs tail /${PROJECT_NAME}/efs/db-staging --follow`로 따라가고, SSM 파라미터 `/${PROJECT_NAME}/efs/db-staging-status`가 `completed:<db>:<prefix>:<seconds>`가 될 때까지 기다린다. nt는 2~3시간: NFS 클라이언트 1대의 쓰기 상한이 1,500 MiB/s이고, EFS Elastic 처리량은 쓰기 GB당 $0.06을 받는다(nt 약 $72). 호스트는 끝나면 스스로 정지한다.

### 3. FSx for Lustre와 S3 복사

```bash
aws cloudformation deploy --stack-name ${PROJECT_NAME}-lustre \
  --template-file 03-lustre-storage.yaml --capabilities CAPABILITY_IAM \
  --parameter-overrides ProjectName=$PROJECT_NAME BlastDbName=$BLAST_DB \
    S3BucketName=blast-nt-lustre LustreStorageCapacity=$LUSTRE_GIB --region $AWS_REGION
```

복사는 S3 -> S3 서버 측 복사다. us-east-1에서는 전송 요금이 없고, 다른 리전이면 us-east-1에서 나가는 $0.02/GB가 붙는다. `/${PROJECT_NAME}/lustre/db-s3-copy` 로그와 `/${PROJECT_NAME}/lustre/db-s3-copy-status` 파라미터를 본다. 파일 시스템 생성 시점에 버킷이 비어 있으므로 템플릿은 `AutoImportPolicy: NEW_CHANGED`를 둔다. 복사된 객체는 `/mnt/lustre/<db>/`에 메타데이터로만 나타나고 내용은 첫 읽기 때 S3에서 가져온다(이 첫 읽기가 Lustre 잡의 `db_setup_seconds`다).

잡 밖에서(시간 측정 없이) 미리 적재하려면 파일 시스템을 마운트한 인스턴스에서:

```bash
nohup find /mnt/lustre/nt -type f -print0 | xargs -0 -n 50 -P 8 sudo lfs hsm_restore &
```

### 4. 쿼리 버킷과 Batch

QUICKSTART 4단계 참조. `QueryS3Key` 기본값은 `queries/query.fasta`. 결과는 `s3://<query-bucket>/results/<scenario>/results-<timestamp>.out`(1회차 패스 출력)에 저장된다.

### 5. 실행과 결과 읽기

```bash
./run_tests.sh                    # 또는 ./run_tests.sh efs, ./run_tests.sh --concurrency 4 (큐당 N잡 동시 제출; MaxvCpus=384이면 최대 8)
./analyze_performance.py --region $AWS_REGION --project $PROJECT_NAME [--run <timestamp>] [--json out.json]
```

각 잡은 CloudWatch Logs에 기계가 읽을 수 있는 줄을 남긴다:

```
METRIC scenario=lustre job=<id>
METRIC instance_type=r6id.12xlarge
METRIC db_setup_seconds=1830 (lustre hydration via vmtouch -t)      # efs: 0 ; s3: 다운로드(db_bytes, mbps 포함)
METRIC pass=1 blast_seconds=2210 rows=92467 sha256=3f1c...          # 콜드
METRIC pass=2 blast_seconds=2190 rows=92467 sha256=3f1c...          # 웜 (nt는 RAM보다 크므로 콜드와 같음)
METRIC total_seconds=4120
```

비교 포인트:

- `db_setup_seconds`: 이 인스턴스의 스토리지 계층을 채우는 1회 비용.
- `pass=1 blast_seconds`: 스토리지 바운드 검색 시간. nt에서는 이 값이 세 계층의 순위를 정한다.
- `pass=2`: RAM에 들어가는 DB(core_nt)면 세 시나리오가 여기서 수렴해야 한다. nt는 1회차와 같고 다시 스토리지 계층을 보여 준다.
- `sha256`: 정렬 출력 해시는 시나리오·실행 간 동일해야 한다. 다르면 DB 스냅샷이 다른 것이다(EFS의 `SOURCE_PREFIX`와 S3 복사본의 것을 비교).

시나리오마다 최소 2회 실행한다. 클라우드 스토리지 처리량은 실행마다 달라진다(Lustre 버스트 크레딧, EFS·S3 요청 속도 램프업).

## 문제 해결

### 잡이 RUNNABLE에 머문다

`aws batch describe-jobs ... --query 'jobs[].statusReason'`

- `MISCONFIGURATION:JOB_RESOURCE_REQUIREMENT`: `JobVcpus`/`JobMemoryMiB`가 `InstanceTypes`의 모든 타입을 초과. 48 / 370,000은 12xlarge에 맞는다. 384 GiB 전체를 요청하지 말 것.
- 이유 없이 컴퓨팅 환경이 인스턴스 0대: EC2 온디맨드 R 인스턴스 vCPU 쿼터 부족(동시 잡당 48 vCPU) 또는 리전/AZ에 타입 미제공
  (`aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=r6id.12xlarge`).
  `aws batch describe-compute-environments --query 'computeEnvironments[].{n:computeEnvironmentName,s:status,r:statusReason}'` 확인.
- 스팟: 기본 미사용. 컴퓨팅 환경을 `SPOT`으로 바꾸면 `spotIamFleetRole`이 필요하고 1~2시간 잡 중 회수를 감안해야 한다.

### 잡이 즉시 실패한다

- `aws: command not found`: 이미지에 AWS CLI가 없다. `BlastImage`를 ElasticBLAST 이미지로 유지하거나 awscli를 넣어 직접 빌드.
- `s3` 시나리오에서 `No such file or directory: /mnt/nvme` 또는 `No space left on device`: 런치 템플릿이 실행되지 않았거나 인스턴스에 인스턴스 스토어가 없다. 콘솔 출력 / `lsblk` 확인. 풀은 d형이어야 한다.
- `BLAST Database error: No alias or index file found for nucleotide database [/mnt/efs/nt/nt]`: 스테이징 미완료 또는 스택 간 DB 이름 불일치. SSM 상태 파라미터와 스테이징 호스트에서 `ls /mnt/efs/nt | head` 확인(`aws ec2 start-instances`로 켠다).
- Lustre: `mount.lustre: ... Input/output error` 또는 빈 `/mnt/lustre`: 보안 그룹 988 누락, 컴퓨팅이 파일 시스템과 다른 서브넷(단일 AZ라서 Lustre 컴퓨팅 환경은 프라이빗 서브넷 1에 고정), 또는 `AutoImportPolicy` 미적용.
  `aws fsx describe-file-systems --query 'FileSystems[].LustreConfiguration.DataRepositoryConfiguration'` 확인.

### 스테이징이 끝나지 않는다

- `aws logs tail /${PROJECT_NAME}/efs/db-staging`에 `s3://ncbi-blast-databases`에 대한 `403`: 인스턴스 역할에 그 버킷의 `s3:GetObject`/`s3:ListBucket`(포함됨)과 S3 egress 경로(NAT 또는 게이트웨이 엔드포인트, 둘 다 포함됨)가 필요하다.
- 상태 파라미터가 없다: 역할의 `ssm:PutParameter`는 `/<project>/*`로 제한된다. 네트워크 스택과 다른 `ProjectName`을 쓰면 `ImportValue`와 이 범위가 모두 깨진다.

### Lustre 첫 패스가 느리다

SCRATCH_2 처리량은 용량에 비례한다: 기준 200 MB/s/TiB(2,400 GiB -> 약 470 MB/s), 네트워크 크레딧으로 1,300 MB/s/TiB까지 버스트. 1.2 TB 첫 읽기는 기준 속도에서 약 42분. 지속 처리량이 필요하면 `PERSISTENT_2` 500 또는 1,000 MB/s/TiB(`DeploymentType` 변경 + `PerUnitStorageThroughput` 추가, GB-월당 $0.34 / $0.60) 또는 용량 증설.

## 정리

```bash
./cleanup.sh
```

또는 `${PROJECT_NAME}-batch`, `-lustre`, `-efs`, `-network` 순으로 삭제 후 버킷 2개(`${PROJECT_NAME}-queries-<account>`, `blast-nt-lustre-<account>`) 삭제. 스테이징 인스턴스는 각 스택에 속해 함께 삭제된다.

## 비용 메모

README의 비용 표 참조. 요약: EFS 스토리지 $0.30/GB-월 + 쓰기 $0.06/GB + 읽기 $0.03/GB(읽기 때문에 nt 콜드 패스 1회가 약 $35); FSx SCRATCH_2 $0.14/GB-월, 프로비저닝 용량에 대해 시간 단위 과금; S3 복사본 $0.023/GB-월; 컴퓨팅은 잡 실행 중 12xlarge 1대 $3.6/h. 벤치마크 라운드 사이에는 스토리지를 내린다.
