# grafana — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `grafana/grafana:13.0.2` (`docker.io/grafana/grafana`, 2026-06-02 릴리스, 2026-06-10 기준 최신 안정)

Prometheus 메트릭 시각화 대시보드. 외부 접근은 Cloudflare Tunnel + Access(GitHub IdP)로 게이트 (cloudflare-tunnel.md). `latest` 금지, 정확한 patch 핀. 업그레이드 시 릴리스 노트 확인.

Helm chart: 자체 작성 (`edge/helm/grafana/`). datasource·대시보드를 provisioning ConfigMap으로 선언해 무상태에 가깝게 운영.

## 주요 설정

datasource와 대시보드를 provisioning으로 선언하고, 외부 노출 호스트명을 `root_url`에 맞추는 것이 핵심.

```yaml
# values.yaml — 환경변수/서버
env:
  GF_SERVER_ROOT_URL: "https://grafana.<domain>/"   # Cloudflare Tunnel 호스트명과 일치 — 아래 주의사항
  GF_SECURITY_ADMIN_PASSWORD__FILE: /etc/secrets/admin-password  # Secret 주입, 평문 금지
  GF_USERS_ALLOW_SIGN_UP: "false"
  GF_AUTH_ANONYMOUS_ENABLED: "false"
```

```yaml
# datasource provisioning (ConfigMap → /etc/grafana/provisioning/datasources)
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus.gikview.svc:9090
    isDefault: true
```

```yaml
# dashboard provisioning (ConfigMap → /etc/grafana/provisioning/dashboards)
# 대시보드 JSON을 ConfigMap으로 마운트 → 코드로 버전관리. 수기 편집분은 재시작 시 유실 주의
```

스토리지: 대시보드/datasource를 provisioning으로 두면 Grafana 내부 DB(sqlite)는 사용자/세션 정도만. PVC 작게(1~2Gi) 또는 emptyDir(설정이 전부 provisioning이면 손실 허용). microSD 부하 최소화.

`port: 3000`.

## 알려진 주의사항

- **`root_url` 불일치로 redirect 깨짐**: Cloudflare Tunnel 뒤에서 `GF_SERVER_ROOT_URL`이 실제 외부 호스트명과 다르면 로그인/OAuth redirect, 정적 asset 경로가 깨져 빈 화면 또는 무한 리다이렉트. 터널 public hostname과 정확히 일치시킬 것. 서브패스로 노출하면 `GF_SERVER_SERVE_FROM_SUB_PATH: "true"`도 필요.

- **인증 중복/우회**: 외부 인증은 Cloudflare Access(GitHub IdP, cloudflare-tunnel.md)가 담당. Grafana 자체 로그인을 켜두면 이중 로그인. Cloudflare Access가 주입하는 `Cf-Access-Authenticated-User-Email` 헤더로 `auth.proxy`를 쓰면 SSO 단일화 가능. 단 그 경우 **Grafana svc가 Access를 우회해 직접 접근되면 헤더 위조로 무인증 로그인** 가능 → svc를 ClusterIP 내부 전용으로 두고 터널만 진입점으로 유지(NodePort/Ingress로 직접 노출 금지).

- **admin password 평문**: `GF_SECURITY_ADMIN_PASSWORD`를 values에 직접 두면 git 평문. `__FILE` 변형 + Secret 마운트.

- **provisioning 덮어쓰기**: provisioning ConfigMap이 있으면 UI에서 수정한 datasource/대시보드가 재시작 시 덮어써짐. 대시보드는 JSON을 ConfigMap에 반영하는 흐름으로 관리.

- **plugin 설치와 readOnlyRootFilesystem**: 런타임 plugin 설치는 쓰기 경로 필요. 미리 이미지에 포함하거나 emptyDir `/var/lib/grafana/plugins` 마운트.

## 환경별 분리 필요 항목

| 항목 | dev (alpha) | prod (edge) |
|------|-----|------|
| `nodeSelector` (node_category: monitoring) | `alpha-w2` | `e-s2` |
| `GF_SERVER_ROOT_URL` | dev 터널 호스트명 | prod 터널 호스트명 |
| admin password Secret | dev 값 | prod 값 |

datasource URL(클러스터 내부 svc)·port는 환경 공통.
