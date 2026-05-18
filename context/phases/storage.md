# Phase: storage

## Service: influxdb

**technology**: influxdata/influxdb (3.9-core)
**dependency**: [none]
**artifacts**: helm
**node_category**: [storage]
**references**: [context/knowledge/influxdb.md]

- InfluxDB 3 Core 단일 Pod non-HA 배포.
  - master 노드 고정 (nodeSelector: `kubernetes.io/hostname`). master 자원 부담은 운영 후 재평가.
  - 데이터 영속화: nodeAffinity 가 묶인 local PV 매니페스트로 외장 SSD 위치 명시. etcd 디렉토리 (`/mnt/ssd/etcd`) 와 분리된 `/mnt/ssd/influxdb` 사용. `reclaimPolicy: Retain` 으로 helm uninstall 시에도 데이터 보존.
  - object store 모드 `file` (S3 미사용).
  - **OS 사전 작업** (사람 1 회, 운영환경): 외장 SSD `/mnt/ssd` 마운트 + `/etc/fstab` 등록 + 디렉토리 분리 + `chown 1500:1500 /mnt/ssd/influxdb`.

- **인증** — Token Provisioning (v3.4+) 패턴.
  - 사람 1 회 (환경마다): `influxdb3 create token --admin --offline --expiry 10y` 로 token JSON 사전 생성 → K8s Secret `influxdb-admin-token` 으로 등록 (`admin-token.json` + `token` 두 키).
  - Pod args `--admin-token-file=/var/run/secrets/influxdb/admin-token.json` + Secret mount → 첫 기동 시 자동 등록 (멱등). helm 재배포 시 동일 token 재사용.
  - Token 만료 10 년. 만료 전에 새 JSON 생성 → Secret 갱신 → Pod restart.

- **Database 생성** — Helm post-install / post-upgrade hook Job.
  - 대상 database: `gikview`, retention `none` (무제한).
  - Job 이 admin token 을 `secretKeyRef` 로 받아 InfluxDB API 호출. 이미 존재하면 무시 (멱등).

- **Port**:
  - `http: 8181` — HTTP API (write · query · admin 통합). ClusterIP 만, 외부 노출 없음.

- **리소스**:
  - CPU: `200m` / `500m`
  - Memory: `256Mi` / `512Mi`

- **Persistence**:
  - storageClass: `local-storage` (manual local PV)
  - size: `50Gi` (prod), `5Gi` (dev)
  - reclaimPolicy: `Retain`
