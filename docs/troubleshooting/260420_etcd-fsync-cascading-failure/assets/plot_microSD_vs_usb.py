#!/usr/bin/env python3
"""
microSD vs USB 3.0 성능 비교 그래프 생성 스크립트

사용법:
  python3 plot_microSD_vs_usb.py \
    --sd-iostat ../raw/emqx-deploy_load/testD_microSD_032740_iostat.log \
    --sd-mpstat ../raw/emqx-deploy_load/testD_microSD_032740_mpstat.log \
    --usb-iostat ../raw/emqx-deploy_load/testD_usb_012516_iostat.log \
    --usb-mpstat ../raw/emqx-deploy_load/testD_usb_012516_mpstat.log \
    --sd-device mmcblk0 \
    --usb-device sda \
    --output ../assets/result_microsd_vs_usb.png

출력:
  - 2 subplot 통합 이미지 1개
    상단: write latency (w_await, log scale)
    하단: CPU usage (usr+sys)
"""

import argparse
import os
import sys

import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt


def parse_mpstat(path):
    """mpstat -P ALL 1 로그에서 'all' 행만 추출."""
    series = []
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 11:
                continue
            # 포맷: "HH:MM:SS all usr nice sys iowait irq soft steal guest gnice idle"
            if parts[1] == 'all':
                try:
                    usr = float(parts[2])
                    sys_ = float(parts[4])
                    iowait = float(parts[5])
                    series.append({
                        'cpu': usr + sys_,
                        'iowait': iowait,
                    })
                except (ValueError, IndexError):
                    continue
    return series


def parse_iostat(path, device):
    """iostat -xz 1 로그에서 특정 device 행만 시계열로 추출.

    첫 번째 샘플은 시스템 부팅 이후 누적 평균이므로 제외.
    """
    series = []
    with open(path) as f:
        for line in f:
            if line.startswith(device + ' '):
                parts = line.split()
                try:
                    w_s = float(parts[7])
                    w_await = float(parts[11])
                    util = float(parts[22])
                    series.append({
                        'w_s': w_s,
                        'w_await': w_await,
                        'util': util,
                    })
                except (ValueError, IndexError):
                    continue
    # 첫 샘플 (누적 평균) 제외
    return series[1:] if len(series) > 1 else series


def plot_combined(sd_mp, usb_mp, sd_io, usb_io, output_path):
    """통합 그래프 - 상단: write latency, 하단: CPU usr+sys."""
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7), sharex=True)

    # 상단: write latency (log scale)
    ax1.plot(range(len(sd_io)), [r['w_await'] for r in sd_io],
             color='#d62728', label='microSD', alpha=0.75, linewidth=0.9)
    ax1.plot(range(len(usb_io)), [r['w_await'] for r in usb_io],
             color='#1f77b4', label='USB 3.0', alpha=0.75, linewidth=0.9)
    ax1.axhline(y=25, color='gray', linestyle='--', alpha=0.5, linewidth=0.8,
                label='etcd recommended (25ms)')
    ax1.set_yscale('log')
    ax1.set_ylabel('w_await (ms, log scale)', fontsize=11)
    ax1.set_title('Storage performance during EMQX deploy - microSD vs USB 3.0',
                  fontsize=13, fontweight='bold')
    ax1.legend(loc='upper right')
    ax1.grid(True, alpha=0.3, which='both')

    # 하단: CPU usr+sys
    ax2.plot(range(len(sd_mp)), [r['cpu'] for r in sd_mp],
             color='#d62728', label='microSD', alpha=0.75, linewidth=0.9)
    ax2.plot(range(len(usb_mp)), [r['cpu'] for r in usb_mp],
             color='#1f77b4', label='USB 3.0', alpha=0.75, linewidth=0.9)
    ax2.set_xlabel('Time (s)', fontsize=11)
    ax2.set_ylabel('CPU usr+sys (%)', fontsize=11)
    ax2.legend(loc='upper right')
    ax2.grid(True, alpha=0.3)
    ax2.set_ylim(0, 100)

    plt.tight_layout()
    plt.savefig(output_path, dpi=110, bbox_inches='tight')
    plt.close()
    print(f"Saved: {output_path}")


def print_summary(sd_mp, sd_io, usb_mp, usb_io):
    """통계 요약."""
    import statistics as st

    def pctl(data, p):
        if not data:
            return 0
        s = sorted(data)
        k = int(len(s) * p / 100)
        return s[min(k, len(s) - 1)]

    sd_w = [r['w_await'] for r in sd_io]
    usb_w = [r['w_await'] for r in usb_io]
    sd_iow = [r['iowait'] for r in sd_mp]
    usb_iow = [r['iowait'] for r in usb_mp]
    sd_cpu = [r['cpu'] for r in sd_mp]
    usb_cpu = [r['cpu'] for r in usb_mp]

    print("\n=== Summary ===")
    print(f"{'Metric':<22}{'microSD':>14}{'USB 3.0':>14}{'Ratio':>10}")
    print("-" * 60)

    def row(name, sd_v, usb_v, fmt='{:.2f}'):
        ratio = sd_v / usb_v if usb_v > 0 else float('inf')
        print(f"{name:<22}{fmt.format(sd_v):>14}{fmt.format(usb_v):>14}"
              f"{ratio:>8.1f}x")

    row('w_await avg (ms)', st.mean(sd_w), st.mean(usb_w))
    row('w_await p95 (ms)', pctl(sd_w, 95), pctl(usb_w, 95))
    row('w_await p99 (ms)', pctl(sd_w, 99), pctl(usb_w, 99))
    row('w_await max (ms)', max(sd_w), max(usb_w))
    row('iowait avg (%)', st.mean(sd_iow), st.mean(usb_iow))
    row('iowait max (%)', max(sd_iow), max(usb_iow))
    row('CPU usr+sys avg (%)', st.mean(sd_cpu), st.mean(usb_cpu))


def main():
    parser = argparse.ArgumentParser(
        description='microSD vs USB 3.0 성능 비교 그래프 생성')
    parser.add_argument('--sd-iostat', required=True,
                        help='microSD iostat 로그 경로')
    parser.add_argument('--sd-mpstat', required=True,
                        help='microSD mpstat 로그 경로')
    parser.add_argument('--usb-iostat', required=True,
                        help='USB 3.0 iostat 로그 경로')
    parser.add_argument('--usb-mpstat', required=True,
                        help='USB 3.0 mpstat 로그 경로')
    parser.add_argument('--sd-device', default='mmcblk0',
                        help='microSD 디바이스명 (default: mmcblk0)')
    parser.add_argument('--usb-device', default='sda',
                        help='USB 디바이스명 (default: sda)')
    parser.add_argument('--output', default='result_storage_comparison.png',
                        help='출력 이미지 경로 (default: result_storage_comparison.png)')

    args = parser.parse_args()

    # 입력 파일 확인
    for f in [args.sd_iostat, args.sd_mpstat, args.usb_iostat, args.usb_mpstat]:
        if not os.path.exists(f):
            print(f"ERROR: file not found: {f}", file=sys.stderr)
            sys.exit(1)

    # 출력 디렉토리 생성
    output_dir = os.path.dirname(args.output)
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)

    # 파싱
    sd_mp = parse_mpstat(args.sd_mpstat)
    usb_mp = parse_mpstat(args.usb_mpstat)
    sd_io = parse_iostat(args.sd_iostat, args.sd_device)
    usb_io = parse_iostat(args.usb_iostat, args.usb_device)

    print(f"Parsed: microSD mpstat={len(sd_mp)}, iostat={len(sd_io)}")
    print(f"Parsed: USB 3.0 mpstat={len(usb_mp)}, iostat={len(usb_io)}")

    if not (sd_mp and usb_mp and sd_io and usb_io):
        print("ERROR: 파싱 결과가 비어있음. 디바이스명 또는 로그 포맷 확인.",
              file=sys.stderr)
        sys.exit(1)

    # 통합 그래프 생성
    plot_combined(sd_mp, usb_mp, sd_io, usb_io, args.output)

    # 요약 출력
    print_summary(sd_mp, sd_io, usb_mp, usb_io)


if __name__ == '__main__':
    main()