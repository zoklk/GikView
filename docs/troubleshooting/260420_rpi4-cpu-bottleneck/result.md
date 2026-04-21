# 최종 상태

## 근본 원인

K3s 임베디드 etcd의 fsync write가 microSD의 sync write IOPS 한계(약 67 IOPS)를 초과하여 write latency가 폭증. EMQX 배포와 같은 write burst 상황에서 raft election timeout(기본 500ms)을 수 배 상회하는 지연이 발생하며 etcd quorum이 흔들렸고, 이어 apiserver 응답 불가 및 노드 간 cascading failure로 이어짐. 이 구조는 **저장매체의 구조적 한계**가 단일 원인으로 기여한 결과로, approach-01의 H1에서 확정됨.

확정 경로: [approach-01.md](approach-01.md)

## 해결 조치

### 저장매체 교체

- e-s1의 etcd 데이터 경로(`/var/lib/rancher`)를 microSD에서 USB 3.0 외장 저장매체로 임시 이전 (추후 외장 ssd로 전환 예정)

### 클러스터 구조 전환

- K3s HA(server × 3) 구조를 **단일 control-plane(e-s1) + 2 agent(e-s2, e-s3)** 구조로 전환하여 etcd fsync 복제 부담 제거
  - 추가로 gikview의 경우 트래픽이 burst한 상황이 없어 pod의 재스캐줄링 가능성이 낮음.
  - 따라서 가능한 대안이었던 '3노드 저장장치 변경'보다 단일 master노드로의 변환이 효율적이라 판단.

### 워크로드 배치 조정

- EMQX 워크로드를 worker 노드(e-s2, e-s3)에만 배치. 이유는 두 가지:
  - control-plane 노드(e-s1) 자원 집중 회피
  - **EMQX 초기 클러스터링 시 Erlang VM 기동이 유발하는 CPU burst**가 e-s1에서 동시 발생할 경우 control-plane 응답성에 영향을 줄 수 있어 분리

### L2 Announcement → NodePort 전환

- Cilium L2 Announcement를 사용한 단일 VIP 진입 구조를 제거하고 NodePort 직접 노출로 전환
- 전환 배경:
  - **저장매체 이슈 해소 과정에서 control-plane을 1개로 축소**했고, Cilium L2 Announcement는 lease 갱신에 apiserver를 사용하므로 e-s1 단독 장애 시 VIP 광고가 중단되는 **SPOF 리스크**가 생김
  - 이 서비스는 **Pod가 특정 노드에 정적 배치**되고 **센서 트래픽이 5초 주기로 일정**하여, 로드밸런서의 동적 재라우팅 필요성이 낮음
- 일반적으로 NodePort는 **노드 IP/포트 변경 시 펌웨어 재배포 부담**, **엔드포인트 관리 복잡도**로 권장되지 않지만, 본 서비스는 다음 조건으로 이 단점이 사실상 발생하지 않음:
  - edge 노드와 공유기가 **고정 IP**로 IP 변경 가능성 없음
  - EMQX 배치 노드가 **2개로** 센서 펌웨어가 관리하기에 충분

## 핵심 수치

<img src="./assets/result_microsd_vs_usb.png" height="350">

EMQX Helm install 300초 구간을 iostat과 mpstat로 1초 간격 측정한 결과.

상단 그래프는 etcd 데이터 경로 디스크의 write latency(w_await, log scale). microSD 환경에서는 배포 시작 후 30~150초 구간에 w_await이 1,000ms~8,000ms 범위로 폭증하며 etcd 권장 기준(25ms)을 2~3자릿수 배수로 초과. USB 3.0 환경에서는 전 구간 5ms 수준으로 안정되어 기준 이하를 유지.

하단 그래프는 노드 CPU 사용률(usr+sys). microSD 환경에서는 동일 구간에 CPU가 낮게 측정되는데, 이는 유휴가 아니라 iowait에 막혀 CPU가 진행할 수 없는 상태. USB 3.0 환경에서는 I/O 대기가 해소되어 Erlang VM이 정상적으로 CPU를 사용하며 평균 37% 수준으로 올라감. CPU 자체는 병목이 아니었고, I/O가 CPU를 막고 있었다는 점을 보여주는 대비.
p95 기준 write latency는 3,608ms → 5.6ms로 약 640배 개선되었고, 이 변화만으로 기존의 cascading failure가 더 이상 재현되지 않음.

## 남은 과제

- e-s2, e-s3도 microSD 기반이므로 해당 노드에 I/O 워크로드 최소화 필요.