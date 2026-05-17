# 외장 USB SSD JMS567 + UAS 드라이버 wedge로 e-s1 etcd 간헐 마비

> 이 디렉토리의 문서는 Claude(Anthropic)를 활용해 작성됨.

- 발생: 2026-05-17
- 상태: 문제 해결
- 관련: [etcd-fsync-cascading-failure](../260420_etcd-fsync-cascading-failure/README.md)
- 참고: [Red Hat Bugzilla #1315013 — JMicron USB to SATA Bridge JMS56x Series requires usb-storage quirks to disable
uas](https://bugzilla.redhat.com/show_bug.cgi?id=1315013)

## 증상

e-s1(K3s 단일 control-plane)의 etcd가 간헐적으로 마비. `kubectl get pod`이 무응답이 되고 apiserver가 다운됨. 커널 로그에 동일
시그니처가 반복:

EXT4-fs warning (device sda1): ... error -5 ... reading directory block

error -5(EIO)가 etcd 데이터 디렉토리가 위치한 외장 USB SSD(`/dev/sda1`)에 대한 모든 I/O에서 발생. 장치는 마운트된 상태로 남아 있어 USB
연결 끊김이 아니라 명령 계층에서 wedge된 형태. 재부팅 시 일시 정상화되나 부하가 누적되면 재발.

**환경**
- e-s1: RPi4 8GB, Ubuntu Server 24.04 arm64, K3s v1.34.6 (단일 control-plane)
- etcd 데이터 디렉토리: `/var/lib/rancher/k3s/server/db/etcd` → 외장 USB SSD(`/dev/sda1`)
- 외장 케이스: JMicron JMS567 USB-SATA 브리지 (VID:PID `152d:0562`)
- 드라이버: `uas` (USB Attached SCSI, 커널 기본 바인딩)

## 접근

### Approach 1 — 매체/파일시스템 배제 후 USB-SATA 브리지 식별

- 동기: ext4 EIO 도배 + 장치는 마운트 유지 + 재부팅 시 일시 회복 + 부하 누적 시 재발이라는 패턴 조합. 매체 결함이라면 회복이 일관되지
않고, 파일시스템 결함이라면 fsck 후 시그니처가 달라져야 하는데 둘 다 해당 없음 → 매체/링크보다 위 계층(USB-SATA 브리지 또는
드라이버)에서 wedge될 가능성 의심.
- 가설:
- H1 ext4 메타데이터 손상으로 디렉토리 블록 read 실패: **기각** (재부팅 후 fsck 클린, 동일 디스크에서 동일 시그니처 재발)
- H2 SSD 매체 자체 결함: **기각** (`/dev/sda1` 마운트 유지, 별도 호스트에서 정상 동작)
- H3 USB-SATA 브리지(JMS567)가 `uas` 드라이버 조합에서 etcd fsync 위주 부하에 펌웨어 wedge: **채택**
- 검증 명령:
    - `lsusb` → `152d:0562 JMicron ... JMS567 SATA 6Gb/s bridge` 확인
    - `lsusb -t` → 해당 장치 `Driver=uas` 확인
    - `df -h /var/lib/rancher/k3s/server/db/etcd` → `/dev/sda1` 정상 마운트 → 마운트/bind 계층 배제
    - `journalctl -k -b | grep -i 'EXT4-fs'` → `error -5 reading directory block` 반복
- 종합 결론: JMS567 + UAS 조합은 다수 배포판 버그 트래커(Red Hat #1315013, Ubuntu LP #1789589 등)에 펌웨어 결함으로 등재. VID:PID
`152d:0562`는 커널의 자동 UAS 블랙리스트 미등록 장치이므로 수동 quirk 지정 필요. etcd처럼 작고 잦은 fsync가 누적되면 브리지 펌웨어의
명령 큐가 wedge되어 모든 I/O가 EIO로 떨어지는 메커니즘.

## 해결

`uas` 드라이버를 비활성화하고 `usb-storage`(BOT) 모드로 폴백. JMS567은 BOT 모드에서 안정 동작. USB 3.0 일부 성능을 손해보지만 etcd
fsync 부하 수준에서는 영향 없음.

1. `/boot/firmware/cmdline.txt`의 **기존 한 줄 맨 뒤에 공백으로 구분해 추가**. cmdline.txt는 한 줄 파일이며 줄바꿈 금지.
    usb-storage.quirks=152d:0562:u
`152d:0562` = JMS567 VID:PID, `u` = IGNORE_UAS.

2. 재부팅.

3. 검증
- `cat /proc/cmdline` 출력에 `usb-storage.quirks=152d:0562:u` 포함
- `lsusb -t`에서 해당 장치 `Driver=usb-storage` (uas 아님)
- `journalctl -k -b | grep 'EXT4-fs'`에 `error -5` 미발생

주의: `152d:0562`는 외장 케이스(브리지 칩) 고유 VID:PID. 케이스 교체 시 `lsusb`로 새 VID:PID를 확인하고 quirk 값을 갱신할 것.