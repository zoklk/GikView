# influxdb — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `influxdb:3.9-core` (`docker.io/library/influxdb:3.9-core`)

InfluxDB 3 Core 는 MIT / Apache 2 라이선스로 배포되는 단일 노드 시계열 엔진. 저장 포맷은 Apache Parquet (컬럼 지향) + DataFusion 쿼리 엔진. 본 프로젝트의 raw timeseries 적재 (9 대 × 5 초 polling) 규모에서는 Core 로 충분하며, HA · long-range query 가속 · fine-grained resource token 이 필요한 Enterprise 기능은 범위 외.

`3.9-core` 태그를 사용하는 이유: 마이너 버전을 3.9 로 고정해 예기치 않은 메이저 / 마이너 변경을 차단하면서 같은 마이너 안의 패치 (3.9.2 → 3.9.x) 는 자동 흡수.

> 2026-05-27 부터 InfluxData 의 `latest` 태그가 InfluxDB 3 Core 로 이전됨. `latest`, `core`, `3-core` 같은 floating tag 는 silent breaking change 위험이 있어 사용 금지.

Helm chart: 자체 작성. InfluxData 공식 chart 는 Enterprise (beta) 만 제공되며 Core 용 공식 chart 없음. 단일 Pod + PVC + Token Provisioning 패턴이라 자체 chart 가 트러블슈팅 면에서 단순.

## 주요 설정

InfluxDB 3 Core 는 `serve` 서브커맨드의 명령줄 인자로 모든 핵심 설정을 받음. 클러스터링 관련 설정 없음.

```yaml
# values.yaml (공통)
influxdb:
  args:
    - "serve"
    - "--node-id=$(POD_NAME)"
    - "--object-store=file"
    - "--data-dir=/var/lib/influxdb3/data"
    - "--http-bind=0.0.0.0:8181"
    - "--admin-token-file=/var/run/secrets/influxdb/admin-token.json"

env:
  - name: POD_NAME
    valueFrom:
      fieldRef: { fieldPath: metadata.name }

volumeMounts:
  - { name: admin-token, mountPath: /var/run/secrets/influxdb, readOnly: true }
  - { name: influxdb-data, mountPath: /var/lib/influxdb3/data }

volumes:
  - name: admin-token
    secret:
      secretName: influxdb-admin-token
      items:
        - { key: admin-token.json, path: admin-token.json }
```

### Admin token 부트스트랩 — Token Provisioning (v3.4+)

InfluxDB 자체 인증은 토큰 기반. v3.4 부터 도입된 offline admin token file 기능으로 server 기동 전에 token JSON 을 사전 등록해두면 첫 기동 시 자동 등록 (멱등). 사람 개입은 환경마다 1 회.

```bash
# alpha-m1 에서 그대로 실행 (Atom 이라도 OK)

TOKEN_RAW=$(openssl rand -base64 32 | tr -d '=+/\n' | head -c 32)
TOKEN="apiv3_${TOKEN_RAW}"
EXPIRY_MS=$(($(date +%s) * 1000 + 10 * 365 * 24 * 3600 * 1000))

cat > admin-token.json <<EOF
{
  "token": "${TOKEN}",
  "name": "admin",
  "description": "GikView admin token",
  "expiry_millis": ${EXPIRY_MS}
}
EOF
chmod 600 admin-token.json

# 네임스페이스 없으면 먼저 생성
kubectl create namespace gikview --dry-run=client -o yaml | kubectl apply -f -

# Secret 등록
kubectl create secret generic influxdb-admin-token -n gikview \
    --from-file=admin-token.json=admin-token.json \
    --from-literal=token="${TOKEN}"

# token 값 1Password 등에 별도 백업 후 평문 파일 삭제
shred -u admin-token.json
```

이후 영구

- InfluxDB Pod 가 Secret mount + `--admin-token-file` 으로 첫 기동 시 자동 등록.
- 클라이언트 (Edge Gateway, Grafana 등) 는 같은 Secret 의 `token` 키를 `secretKeyRef` 로 받아 `Authorization: Bearer` 헤더에 사용.
- helm install / uninstall 반복해도 Secret 만 유지되면 동일 token 자동 재등록.
- 만료 갱신 시 새 JSON 생성 → Secret 갱신 → Pod restart 절차.

### Database 생성 — Helm post-install Job

InfluxDB 3 는 database 자동 생성 안 함. Helm chart 의 post-install hook Job 이 책임:

```yaml
# templates/post-install-database-job.yaml (요약)
metadata:
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
        - name: create-database
          image: influxdb:3.9-core
          env:
            - name: INFLUX_TOKEN
              valueFrom:
                secretKeyRef: { name: influxdb-admin-token, key: token }
          command: ["sh", "-c"]
          args:
            - |
              influxdb3 create database gikview \
                --host http://influxdb:8181 \
                --token "$INFLUX_TOKEN" \
                --retention-period none || true
```

- `|| true` 로 멱등 처리 (이미 있으면 409 무시).
- Retention `none` = 무제한. 시간대별 · 요일별 통계용 raw timeseries 보존.

## 알려진 주의사항

- **floating tag 위험**: `latest`, `core`, `3-core` 사용 시 마이너 / 패치 변경이 silent 하게 발생. 반드시 `3.9-core` 같은 마이너 고정 또는 `3.9.2-core` specific 태그 사용.

- **호스트 디렉토리 권한**: local PV 사용 시 호스트 측 디렉토리 소유자가 컨테이너 user (uid 1500) 와 일치해야 함. 불일치 시 WAL 쓰기 권한 거부로 기동 실패. 호스트에서 `chown 1500:1500` 사전 실행 또는 initContainer 로 권한 보정.

- **Database 자동 생성 안 됨**: write API 호출 전에 database 존재 필수. post-install Job 이 책임. Job 실패 시 Edge Gateway write 가 404 로 거부되므로 hook-weight 와 멱등성 중요.

- **Cardinality 폭증 주의**: tag 는 indexed (group by 차원), field 는 indexed 안 됨. **High-cardinality 값 (timestamp, UUID 등) 을 절대 tag 로 두지 말 것**. tag 조합마다 별도 series 생성 → 메모리 / 디스크 폭증.

- **Compaction 의 디스크 I/O burst**: Parquet 기반 LSM 계열 구조. memtable flush + 백그라운드 compaction 시점에 큰 sequential write 몰림. 디스크 공유 환경에서는 같은 디스크의 다른 워크로드 (특히 etcd) latency spike 유발 가능.

- **etcd 와 같은 디스크 공유**: 디렉토리 bind 분리만으로는 IOPS 격리 안 됨 (큐 단일). InfluxDB compaction 이 큐 점령 → etcd WAL fsync 지연 → kube-apiserver 응답 지연 → kubelet / controller-manager lease 갱신 실패 → 노드 NotReady 및 Pod eviction 까지 cascading 가능. **운영 시작 후 baseline 확보 → spike 관측 시 cgroup v2 `io.weight` 적용 → 부족하면 별도 SSD 분리** 의 단계적 접근. 측정 지표는 etcd `wal_fsync_duration_seconds` p99 와 iostat `await`.
  관련: `docs/troubleshooting/260420_etcd-fsync-cascading-failure/`

- **token 손실 복구**: v3.9 부터 admin token recovery server 로 재생성 가능. Token JSON 은 1Password 등에 별도 보관 권장.

- **단일 노드 제약**: Core 는 클러스터링 / read replica 미지원. 노드 장애 = 쓰기 · 조회 모두 중단. 본 프로젝트는 DynamoDB 경로 (변경 이벤트만) 가 사용자 서비스 가용성을 흡수하는 설계로 대응. raw timeseries 손실은 통계 기능에만 영향.

- **Fine-grained token 미지원 (Core)**: v3 Core 는 admin token 만, resource-level (read-only / write-only / per-database) token 은 Enterprise 한정. 본 프로젝트는 모든 client 가 동일 admin token 사용. 보완책은 NetworkPolicy + token 회전.

- **mTLS 권한 매핑 미지원**: 클라이언트 인증서 CN 을 user / token 에 매핑하는 기능 없음. mTLS 추가해도 token 검증을 빼지 못함 (이중 검증). 본 프로젝트는 ClusterIP 노출만 하므로 mTLS 미적용, NetworkPolicy + token 으로 ZT 구성.

- **HTTP/2 강제 (reverse proxy 통과 시)**: HTTP API 와 Apache Flight gRPC 가 같은 8181 포트에서 ALPN 분기. reverse proxy 통과 시 proxy → upstream HTTP/2 활성화 필수. 본 프로젝트는 ClusterIP 직접 호출이라 현재 해당 없음.

## 환경별 분리 필요 항목

| 항목 | dev (alpha cluster) | prod (edge) |
|------|-----|------|
| `nodeSelector` | `kubernetes.io/hostname: alpha-w1` | `kubernetes.io/hostname: e-s1` |
| local PV `spec.local.path` | `/var/lib/influxdb3` | `/mnt/ssd/influxdb` |
| `resources.requests.memory` | `256Mi` | `256Mi` |
| `resources.limits.memory` | `512Mi` | `512Mi` |
| `persistence.size` | `5Gi` | `50Gi` |