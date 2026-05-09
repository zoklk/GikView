# 최종 상태

## 근본 원인

cilium 컨테이너에 번들된 iptables 1.8.8과 호스트 iptables 1.8.10 사이의 nft 표현식 직렬화 포맷 차이. 한쪽이 쓴 룰을 다른 쪽이 `-S`로 텍스트 출력할 때 표현식 필드 정렬이 어긋나 comment buffer의 첫 4 byte("cili")가 IP 슬롯에 함께 표시됨 — 이것이 `99.105.108.105/24`로 보임. 손상은 nft 백엔드 데이터 자체가 아니라 텍스트 출력 시점에 발생.

cilium-agent의 `removeCiliumRules`(`pkg/datapath/iptables/iptables.go`)는 이 텍스트를 검증 없이 `-A`→`-D`로 치환해 그대로 재전송하는 byte-exact replay 구조. 커널은 본문 일치 기반으로 삭제하므로 손상된 텍스트의 `-D`는 거부되고 reconcile은 무한 재시도에 빠짐. 이 상태에서 Pod outbound 트래픽의 SNAT가 적용되지 않아 노드 외부로 나가는 모든 통신(DNS 포함)이 사설 Pod CIDR로 노출되어 라우팅 실패.

`ipv4NativeRoutingCIDR` 미설정은 트리거 조건이 아니며, 손상된 `99.105.108.105/24`도 syntactically valid한 CIDR이므로 `net.ParseCIDR` 같은 단순 검증 가드로는 차단 불가능.

확정 경로: [approach-01.md](approach-01.md)

## 해결 조치

- Cilium Helm values에서 `bpf.masquerade=true`로 전환. SNAT를 eBPF datapath에서 처리하여 iptables `OLD_CILIUM_POST_nat` 정리 경로 자체를 사용하지 않도록 우회 (현장 즉시 조치)
- cilium issue #33465에 재현 결과, cilium sysdump, cilium-internal vs host iptables dump 비교를 보고
- 검증 가드 PR(cilium/cilium#45866)은 손상 CIDR이 syntactically valid해 가드로 못 잡으므로 close
- root cause fix로 `removeCiliumRules`를 line number + target prefix 기반의 본문-무관(body-agnostic) 정리 경로(`removeCiliumFeederRules`)로 재작성하는 PR 제출. `iptables -nL <hook> --line-numbers` 출력의 line number와 jump target 두 컬럼만 읽고 `chainPrefix + "CILIUM_"`으로 매칭, 내림차순으로 line number 기반 삭제. 컨테이너↔호스트 iptables 버전 skew의 영향을 받지 않음

## 남은 과제

- cilium issue #33465 / 신규 PR 진행 추이 추적
- bpf masquerade 전환 후 NodePort outbound 동작 점검
