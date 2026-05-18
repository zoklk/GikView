# Cilium iptables masquerade 룰 손상으로 Pod outbound SNAT 실패

> 이 디렉토리의 문서, 시각화 자료는 Claude(Anthropic)를 활용해 작성됨.

- 발생: 2026-05-07
- 상태: 문제 해결
- 관련: [etcd-fsync-cascading-failure](../260420_etcd-fsync-cascading-failure/README.md)
- 최종 상태: [result.md](result.md)

## 증상

Argo CD가 Application refresh에 반복 실패하며 sync가 진행되지 않음. 디버깅 도중 클러스터 내부 CoreDNS Pod이 외부 DNS 질의에 실패하는 것을 확인. CoreDNS Pod이 떠 있는 노드의 호스트 인터페이스를 `tcpdump`로 캡처하니 outbound 패킷의 source IP가 Pod CIDR(10.0.x.x) 그대로 노출되어 SNAT가 동작하지 않는 상태였음.

cilium-agent 로그에는 약 10초 주기로 reconciliation 에러가 반복:
iptables rules full reconciliation failed: failed to remove old backup rules:
unable to run 'iptables -t nat -D OLD_CILIUM_POST_nat -s 10.0.x.0/24
! -d 99.105.108.105/24 ... -j MASQUERADE'
iptables: Bad rule (does a matching rule exist in that chain?)

`99.105.108.105` = `0x63 0x69 0x6c 0x69` = ASCII `cili`. cilium 컨테이너에 번들된 iptables 바이너리가 호스트와 다른 버전의 iptables가 nft 백엔드에 쓴 룰을 읽으면서 표현식 정렬을 잘못 해석해, comment buffer의 첫 4 byte("cili" — `cilium-feeder` 등에서 유래)가 IP 슬롯으로 흘러나온 결과.

**환경**
- Cilium 1.19.2 (Helm install). 컨테이너 번들 iptables 1.8.8
- K3s v1.34.6, 3 노드 (e-s1 control-plane, e-s2/e-s3 agent), RPi4 arm64
- 호스트 iptables 1.8.10 (컨테이너 번들 버전과 nft 표현식 직렬화 포맷이 다른 버전)
- routing-mode: tunnel (vxlan)
- bpf-masquerade: false (default, iptables 모드)
- `ipv4NativeRoutingCIDR`: 미설정 (`""`)

## 접근

### Approach 1 — 손상된 NAT 룰 추적 및 코드 경로 분석

- 동기: ArgoCD refresh 실패 → CoreDNS DNS 질의 실패 → 호스트 인터페이스 tcpdump에서 outbound SNAT 누락 확인 → cilium-agent 로그의 반복 에러에서 `99.105.108.105` 가비지 값 발견
- 가설:
  - H1 컨테이너 번들 iptables와 호스트 iptables 사이 nft 표현식 직렬화 비호환으로 `iptables -S` 출력에서 comment 바이트가 IP 슬롯으로 leak: **채택**
- 종합 결론: 룰 자체는 nft 백엔드에 정상 저장되어 있으나, 컨테이너 번들 iptables가 다른 버전이 쓴 표현식을 텍스트로 직렬화할 때 필드가 misalign됨. cilium-agent의 정리 경로는 이 손상된 텍스트를 그대로 `-D`로 재전송하므로 커널이 거부하고 reconcile은 무한 재시도에 빠짐. helm `ipv4NativeRoutingCIDR` 미설정은 트리거 조건이 아님.
- 상세: [approach-01.md](approach-01.md)

## 해결

iptables 기반 masquerade 경로 자체를 우회. Cilium Helm values의 `bpf.masquerade=true`로 전환하여 SNAT를 eBPF datapath에서 처리.

상세 수치: [result.md](result.md)
