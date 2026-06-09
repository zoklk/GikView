# node-exporter — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `prom/node-exporter:v1.11.1` (`docker.io/prom/node-exporter`, 2026-04-07 릴리스, 2026-06-10 기준 최신 안정)

노드 단위 하드웨어/OS 메트릭(CPU, memory, disk, filesystem, **iowait**, 온도, network)을 Prometheus 포맷으로 노출하는 표준 exporter. visibility.md 결정 4(InfluxDB SSD filesystem 교차검증)·결정 2(microSD iowait)의 데이터 출처. DaemonSet으로 3노드 전부에 배포.

`latest` 금지, 정확한 patch 핀. 업그레이드 시 릴리스 노트 확인.

Helm chart: 자체 작성 (`edge/helm/node-exporter/`). DaemonSet + hostPath 마운트 패턴이라 단순.

## 주요 설정

호스트 네임스페이스에 접근해야 정확한 메트릭이 나온다. DaemonSet + host 마운트 + control-plane toleration이 핵심.

```yaml
# values.yaml — DaemonSet
hostNetwork: true        # 노드 IP로 :9100 노출 (Prometheus가 노드별 스크랩)
hostPID: true            # 프로세스/메모리 메트릭 정확도
args:
  - "--path.rootfs=/host/root"
  - "--path.procfs=/host/proc"
  - "--path.sysfs=/host/sys"
  - "--collector.filesystem.mount-points-exclude=^/(dev|proc|sys|run)($|/)"
volumeMounts:            # 전부 readOnly
  - { name: proc, mountPath: /host/proc, readOnly: true }
  - { name: sys,  mountPath: /host/sys,  readOnly: true }
  - { name: root, mountPath: /host/root, readOnly: true, mountPropagation: HostToContainer }
volumes:
  - { name: proc, hostPath: { path: /proc } }
  - { name: sys,  hostPath: { path: /sys } }
  - { name: root, hostPath: { path: / } }

tolerations:             # control-plane(e-s1)에도 떠야 함 — 아래 주의사항
  - operator: Exists

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
```

`port: 9100`. Prometheus는 `kubernetes_sd`(role: endpoints) + node-exporter Service로 발견하거나 노드 IP static.

## 알려진 주의사항

- **control-plane 노드 누락 (toleration 없음)**: e-s1(control-plane)에 K3s가 taint를 두면 toleration 없는 DaemonSet pod이 e-s1에 안 뜸 → e-s1의 디스크/iowait/etcd 호스트 메트릭이 통째로 비는데 에러는 없음. visibility의 핵심 노드가 e-s1(etcd+InfluxDB+SSD)이라 치명적. `tolerations: [{ operator: Exists }]`로 모든 taint 허용. 증상: node-exporter 타겟이 노드 수보다 적음.

- **filesystem 메트릭에 가상 fs 혼입**: overlay/tmpfs/k3s 컨테이너 마운트가 `node_filesystem_*`에 섞여 SSD 잔여 용량 알림이 부정확. `--collector.filesystem.mount-points-exclude`로 가상 fs 제외. InfluxDB SSD는 실제 마운트포인트(`/mnt/ssd` 등)로 필터.

- **hostNetwork 포트 충돌**: `:9100`이 노드에서 이미 쓰이면 pod CrashLoop. 충돌 시 `--web.listen-address`로 포트 변경.

- **온도 collector 미지원 노드**: RPi가 아닌 노드/가상화 환경은 `node_hwmon_temp_celsius`가 비어있을 수 있음. 온도 알림은 메트릭 존재 여부 가드 필요.

- **readOnlyRootFilesystem + textfile collector**: textfile collector 쓰면 쓰기 가능 경로 필요. 본 프로젝트 미사용이면 무관.

- **etcd 메트릭은 node-exporter가 아님 (별도 선행 설정)**: e-s1의 etcd fsync/disk latency(visibility.md 결정 5)는 node_exporter가 아니라 etcd 자체 metrics 리스너(`:2381`)에서 나온다. K3s에서 `etcd-expose-metrics: true` + `listen-metrics-urls`를 e-s1 `/etc/rancher/k3s/config.yaml`에 적용하고 k3s 재기동하는 선행 작업이 필요하다. 구체 스니펫과 주의사항은 `prometheus.md`의 "etcd 메트릭 선행 설정" 절 참조.

## 환경별 분리 필요 항목

DaemonSet이라 노드 핀(nodeSelector) 없이 전 노드 배포 — 환경별 노드 차이 없음.

| 항목 | dev (alpha) | prod (edge) |
|------|-----|------|
| filesystem 모니터 대상 마운트포인트 | (해당 클러스터 SSD 경로) | `/mnt/ssd` 계열 (storage.md 결정 2) |

toleration·port·host 마운트는 환경 공통.
