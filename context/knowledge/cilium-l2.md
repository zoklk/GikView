# cilium-l2 — 운영 지식 메모

---
## 개요

Cilium L2 Announcement는 클러스터 외부에서 LoadBalancer Service IP에 접근할 수 있도록
ARP(IPv4) 응답을 노드가 직접 광고하는 기능. MetalLB와 동일한 계층에서 동작하며,
Cilium이 이미 CNI로 설치된 환경에서는 별도 컴포넌트 없이 사용 가능.


## 필수 CRD 구성

### CiliumLoadBalancerIPPool

```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumLoadBalancerIPPool
metadata:
  name: emqx-pool
spec:
  blocks:
    - cidr: "192.168.0.200/32"
  serviceSelector:
    matchLabels:
      app.kubernetes.io/name: emqx-lb   # emqx-lb 서비스에만 할당
```

serviceSelector를 생략하면 클러스터 내 모든 LoadBalancer Service에 IP가 할당될 수 있음.
반드시 명시하여 범위를 제한할 것.

### CiliumL2AnnouncementPolicy

```yaml
apiVersion: "cilium.io/v2alpha1"
kind: CiliumL2AnnouncementPolicy
metadata:
  name: emqx-l2-policy
spec:
  serviceSelector:
    matchLabels:
      app.kubernetes.io/name: emqx-lb
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
  interfaces:
    - ^eth[0-9]+
  externalIPs: false
  loadBalancerIPs: true
```

---알려진 주의사항

- IP 충돌: 192.168.0.200은 네트워크 내 다른 장비와 충돌하지 않아야 함. 사전에 예약된 주소인지 확인 필수.
- nodeSelector: control-plane 노드는 ARP 광고에서 제외. worker 노드만 광고하도록 설정.
- interfaces: 노드의 실제 NIC 이름 패턴에 맞게 수정 필요 (예: ^ens[0-9]+, ^enp[0-9]+s[0-9]+).
- Cilium 설정 전제: l2announcements.enabled: true 및 externalIPs.enabled: true가
Cilium Helm values에 활성화되어 있어야 함. 미리 클러스터 Cilium 설정을 확인할 것.

---환경별 분리 필요 항목

| 항목 | dev | prod |
|------|-----|------|
| `VIP` | `192.168.110.200` | `192.168.0.200` |
| `interfaces 패턴` | `클러스터 NIC 확인 후 설정` | `eth0` |
