"""
fio sync write latency percentile 비교 그래프 생성.

입력: testA_fio_microSD.json, testA_fio_usb30.json
출력: fio-latency-percentile.png

실행:
    python3 plot_fio_latency_percentile.py \
    --microsd ../raw/microSD-io_load/testA_fio_microSD.json \
    --usb30 ../raw/microSD-io_load/testA_fio_usb30.json \
    --output ./testA_microSD_fio-latency.png
"""

import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt


PERCENTILES = ["50.000000", "90.000000", "95.000000",
               "99.000000", "99.500000", "99.900000", "99.990000"]
PERCENTILE_LABELS = ["p50", "p90", "p95", "p99", "p99.5", "p99.9", "p99.99"]

# etcd 권장 기준선 (ms)
ETCD_P99_THRESHOLD_MS = 25


def load_clat_percentiles(path: Path) -> list[float]:
    """fio JSON에서 write clat percentile 값을 ms 단위로 추출."""
    with path.open() as f:
        data = json.load(f)
    pct = data["jobs"][0]["write"]["clat_ns"]["percentile"]
    return [pct[p] / 1_000_000 for p in PERCENTILES]  # ns → ms


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--microsd", required=True, type=Path)
    parser.add_argument("--usb30", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    microsd_ms = load_clat_percentiles(args.microsd)
    usb30_ms = load_clat_percentiles(args.usb30)

    fig, ax = plt.subplots(figsize=(9, 5.5))

    ax.plot(
        PERCENTILE_LABELS, microsd_ms,
        marker="o", markersize=7, linewidth=2,
        color="#d94545", label="microSD",
    )
    ax.plot(
        PERCENTILE_LABELS, usb30_ms,
        marker="s", markersize=7, linewidth=2,
        color="#2e6bd6", label="USB 3.0",
    )

    # etcd 권장 기준선
    ax.axhline(
        y=ETCD_P99_THRESHOLD_MS,
        color="#888888", linestyle="--", linewidth=1,
        label=f"etcd p99 recommended ({ETCD_P99_THRESHOLD_MS} ms)",
    )

    ax.set_yscale("log")
    ax.set_xlabel("Percentile")
    ax.set_ylabel("Latency (ms, log scale)")
    ax.set_title("fio sync write latency by percentile\n"
                 "(4K block, sync=1, fsync=1, iodepth=1, direct=1, runtime=30s)",
                 fontsize=11)

    # 값 레이블
    for x, y in zip(PERCENTILE_LABELS, microsd_ms):
        ax.annotate(f"{y:.1f}", xy=(x, y),
                    xytext=(0, 8), textcoords="offset points",
                    ha="center", fontsize=8, color="#d94545")
    for x, y in zip(PERCENTILE_LABELS, usb30_ms):
        ax.annotate(f"{y:.1f}", xy=(x, y),
                    xytext=(0, -14), textcoords="offset points",
                    ha="center", fontsize=8, color="#2e6bd6")

    ax.grid(True, which="both", linestyle=":", alpha=0.4)
    ax.legend(loc="upper left", framealpha=0.95)
    fig.tight_layout()

    fig.savefig(args.output, dpi=150, bbox_inches="tight")
    print(f"saved: {args.output}")

    print("\nmicroSD (ms):")
    for label, v in zip(PERCENTILE_LABELS, microsd_ms):
        print(f"  {label:>7}: {v:>8.2f}")
    print("\nUSB 3.0 (ms):")
    for label, v in zip(PERCENTILE_LABELS, usb30_ms):
        print(f"  {label:>7}: {v:>8.2f}")


if __name__ == "__main__":
    main()