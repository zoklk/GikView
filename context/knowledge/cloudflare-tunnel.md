# cloudflare-tunnel (cloudflared + Access) — 운영 지식 메모

---

## 이미지 / 버전

**채택**: `cloudflare/cloudflared:2026.5.2` (`docker.io/cloudflare/cloudflared`, 2026-05-27 릴리스, 2026-06-10 기준 최신 안정)

Grafana를 학내망 밖에서 접근하기 위한 outbound-only 터널. cloudflared가 Cloudflare edge로 outbound 연결만 유지하므로 **inbound 포트 노출이 0** (NodePort/포트포워딩 불필요). 외부 인증은 Cloudflare Access + **GitHub IdP**로 게이트 (GitHub 계정 2FA = authenticator). `latest` 금지, 날짜 태그(`YYYY.M.D`) 고정. 업그레이드 시 릴리스 노트 확인.

Grafana만 노출하는 것이 본 단계 범위. step-ca/EMQX(NodePort 직접 노출, security.md 결정 11 / messaging.md 결정 3)와 달리 Grafana는 운영자 대시보드라 외부 접근 + 인증 게이트가 필요해 터널 채택.

Helm chart: 자체 작성 (`edge/helm/cloudflared/`). Deployment(DaemonSet 아님) + token Secret 패턴.

## 주요 설정

원격 관리형(remotely-managed) 터널 채택: 터널 토큰만 cloudflared에 주고, 라우팅(public hostname → 내부 svc)·Access 정책은 Cloudflare 대시보드에서 관리.

```yaml
# values.yaml — Deployment
replicaCount: 2                  # 무중단 (한 pod 재시작 중에도 터널 유지). RPi 부하 보면 1로 축소 가능
args: ["tunnel", "--no-autoupdate", "run"]
env:
  - name: TUNNEL_TOKEN
    valueFrom:
      secretKeyRef: { name: cloudflared-token, key: token }   # 대시보드 발급 토큰, git 평문 금지
containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: { drop: ["ALL"] }
resources:
  requests: { cpu: 20m, memory: 32Mi }
  limits:   { cpu: 100m, memory: 128Mi }
```

### Cloudflare 대시보드 측 (수동, 1회 — 코드 아님)

운영자가 Cloudflare Zero Trust 대시보드에서 수행. cluster-env-inject/배포로 자동화 안 됨:

1. **Tunnel 생성** → `TUNNEL_TOKEN` 발급 → 환경별 K8s Secret(`cloudflared-token`)으로 등록
2. **Public hostname route**: `grafana.<domain>` → `http://grafana.gikview.svc.cluster.local:3000`
3. **Access application**(self-hosted) 생성: 위 호스트명에 대해 **GitHub IdP** 로그인 정책. 허용 GitHub 계정/조직 지정
4. (GitHub 계정에 2FA authenticator 활성화 — 미설정 시 authenticator 게이트 효과 없음)

## 알려진 주의사항

- **TUNNEL_TOKEN = 전체 터널 자격**: 토큰 유출 시 임의 호스트 라우팅 가능. Secret으로만 주입, git 평문 절대 금지. 유출 시 대시보드에서 터널 토큰 재발급.

- **egress UDP 7844(QUIC) 차단**: cloudflared 기본 프로토콜 QUIC는 outbound UDP 7844 필요. 학내망 방화벽이 UDP를 막으면 연결 실패. `--protocol http2`(TCP 443)로 폴백 설정. 증상: cloudflared 로그에 QUIC handshake timeout.

- **Access 우회 직접 접근**: Grafana svc를 NodePort/Ingress로 같이 노출하면 Cloudflare Access를 우회해 무인증 접근 가능. Grafana는 **ClusterIP 내부 전용**으로 두고 터널만 진입점으로 유지 (grafana.md `auth.proxy` 헤더 위조 항목과 동일 맥락).

- **Grafana root_url 불일치**: 터널 호스트명과 `GF_SERVER_ROOT_URL`이 다르면 redirect/asset 깨짐 (grafana.md). 호스트명 확정 후 양쪽 일치.

- **원격관리형 vs 로컬 config 혼용**: `TUNNEL_TOKEN`(원격관리)을 쓰면서 로컬 `config.yaml` ingress 규칙을 같이 두면 충돌/무시. 라우팅을 대시보드에서 관리하기로 했으면 로컬 ingress config 두지 말 것.

- **단일 replica 재시작 공백**: replicaCount 1이면 cloudflared 재시작(이미지 업데이트 등) 중 대시보드 접근 끊김. 운영자 대시보드라 치명도 낮으나 무중단 원하면 2.

## 환경별 분리 필요 항목

| 항목 | dev (alpha) | prod (edge) |
|------|-----|------|
| `nodeSelector` (node_category: monitoring) | `alpha-w2` | `e-s2` |
| `cloudflared-token` Secret | dev 터널 토큰 | prod 터널 토큰 |
| public hostname (`grafana.<domain>`) | dev 서브도메인 | prod 서브도메인 |

GitHub IdP Access 정책·내부 svc 타겟(`grafana.gikview.svc:3000`)은 공통 패턴. egress 프로토콜(QUIC/http2)은 각 망 방화벽에 맞춤.
