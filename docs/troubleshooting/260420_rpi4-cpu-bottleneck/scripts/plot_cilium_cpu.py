"""
Cilium 3-Pod CPU 합계 시계열 그래프 생성 (실제 타임스탬프 기반).

`kubectl top pod -l k8s-app=cilium` 출력 로그를 파싱해 3-Pod CPU 합계를
시간축으로 그린다. x축은 로그에 있는 실제 타임스탬프를 기준 0초로부터의
경과 시간(초)으로 표시.

로그 형식 지원:
  1. 타임스탬프 선행 형식 (testE):
       14:36:17 cilium-xxx 91m 353Mi
       x축: 첫 타임스탬프 기준 실제 경과 초
  2. Pod 라인 + "---" 구분자 형식 (testB baseline):
       cilium-h8vjf   91m   353Mi
       cilium-l44vw   72m   341Mi
       cilium-vwgrg   86m   361Mi
       ---
       x축: 샘플 인덱스를 초로 간주 (대략적)

여러 파일을 인자로 주면 순서대로 이어붙임. 첫 파일이 타임스탬프 형식이면
그 기준으로 실제 시간 사용, 이후 파일은 마지막 샘플 시간에 이어붙임.

실행 예시:

  python3 plot_cilium_cpu.py \
    --inputs ../raw/cilium_load/testB_baseline_cilium.log ../raw/cilium_load/testB_load_cilium.log \
    --segment-boundary 60 \
    --segment-labels "baseline" "load (10 empty services churn)" \
    --title "Cilium 3-Pod CPU sum - testB: empty Service churn" \
    --output ../assets/testB_cilium_cpu.png

  python3 plot_cilium_cpu.py \
    --inputs ../raw/cilium_load2_emqx-lb/testE_cilium_143617.log \
    --annotations "60:install peak (532m, ~13s sustained)" \
    --title "Cilium 3-Pod CPU sum - testE: emqx-lb Helm redeploy" \
    --output ../assets/testE_cilium_cpu.png
"""

import argparse
import re
from pathlib import Path

import matplotlib.pyplot as plt


POD_LINE_WITH_TS = re.compile(r"(\d+:\d+:\d+)\s+cilium-(\S+)\s+(\d+)m")
POD_LINE_PLAIN = re.compile(r"cilium-(\S+)\s+(\d+)m")


def _ts_to_sec(ts: str) -> int:
    h, m, s = ts.split(":")
    return int(h) * 3600 + int(m) * 60 + int(s)


def parse_cilium_log(path: Path) -> list[tuple[int | None, int]]:
    """스냅샷별 (timestamp_sec, cpu_sum) 리스트.

    타임스탬프가 있으면 절대 초(자정부터), 없으면 None.
    """
    result: list[tuple[int | None, int]] = []
    current: dict[str, int] = {}
    current_ts: str | None = None

    def flush() -> None:
        nonlocal current
        if current:
            ts_sec = _ts_to_sec(current_ts) if current_ts else None
            result.append((ts_sec, sum(current.values())))
            current = {}

    with path.open() as f:
        for raw in f:
            line = raw.strip()
            if not line:
                continue

            m1 = POD_LINE_WITH_TS.match(line)
            if m1:
                ts, pod, cpu = m1.group(1), m1.group(2), int(m1.group(3))
                if current_ts is None:
                    current_ts = ts
                if ts != current_ts:
                    flush()
                    current_ts = ts
                current[pod] = cpu
                continue

            m2 = POD_LINE_PLAIN.match(line)
            if m2:
                current[m2.group(1)] = int(m2.group(2))
                continue

            if line.startswith("---"):
                flush()

    flush()
    return result


def build_series(paths: list[Path]) -> tuple[list[int], list[int]]:
    """여러 파일을 이어 붙여 (x_seconds, cpu) 리스트 생성."""
    xs: list[int] = []
    ys: list[int] = []
    offset = 0
    prev_end: int | None = None

    for path in paths:
        snapshots = parse_cilium_log(path)
        if not snapshots:
            raise SystemExit(f"no snapshots parsed from {path}")

        ts_mode = snapshots[0][0] is not None
        if ts_mode:
            base = snapshots[0][0]
            file_xs = [ts - base for ts, _ in snapshots]
        else:
            file_xs = list(range(len(snapshots)))

        if prev_end is not None:
            offset = prev_end + 1

        for x, (_, v) in zip(file_xs, snapshots):
            xs.append(x + offset)
            ys.append(v)
        prev_end = xs[-1]

    return xs, ys


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, nargs="+", type=Path,
                        help="Cilium log 파일 경로들 (순서대로 이어 붙임)")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--title", default="Cilium 3-Pod CPU over time")
    parser.add_argument("--segment-boundary", type=int, default=None,
                        help="구분 수직선 위치(s)")
    parser.add_argument("--segment-labels", nargs="+", default=None,
                        help="각 구간 이름")
    parser.add_argument("--annotations", nargs="*", default=[],
                        help='"x:text" 형식 주석. ex) "60:install peak"')
    args = parser.parse_args()

    xs, ys = build_series(args.inputs)

    fig, ax = plt.subplots(figsize=(10, 4.5))
    ax.plot(xs, ys, linewidth=1.8, color="#2e6bd6", label="3-Pod CPU sum")

    avg = sum(ys) / len(ys)
    ax.axhline(y=avg, color="#888888", linestyle=":", linewidth=1,
               label=f"overall avg {avg:.0f}m")

    if args.segment_boundary is not None:
        ax.axvline(x=args.segment_boundary, color="#d94545",
                   linestyle="--", linewidth=1)

    if args.segment_labels:
        max_x = max(xs)
        if args.segment_boundary is not None:
            mids = [args.segment_boundary / 2,
                    args.segment_boundary + (max_x - args.segment_boundary) / 2]
        else:
            mids = [max_x / 2]
        ymax = max(ys)
        for mid, label in zip(mids, args.segment_labels):
            ax.text(mid, ymax * 1.02, label, ha="center", va="bottom",
                    fontsize=10, color="#333333",
                    bbox=dict(boxstyle="round,pad=0.3",
                              facecolor="white", edgecolor="#cccccc",
                              linewidth=0.5))

    for ann in args.annotations:
        x_str, text = ann.split(":", 1)
        x_target = int(x_str)
        closest_idx = min(range(len(xs)), key=lambda i: abs(xs[i] - x_target))
        x_actual = xs[closest_idx]
        y_actual = ys[closest_idx]
        ax.annotate(
            text, xy=(x_actual, y_actual),
            xytext=(x_actual + 15, y_actual + 40),
            fontsize=9, color="#d94545",
            arrowprops=dict(arrowstyle="->", color="#d94545", lw=1),
        )

    ax.set_xlabel("Time (s)")
    ax.set_ylabel("CPU (millicores)")
    ax.set_title(args.title, fontsize=11)
    ax.set_ylim(bottom=0, top=max(ys) * 1.25)
    ax.grid(True, linestyle=":", alpha=0.4)
    ax.legend(loc="upper left", framealpha=0.95)
    fig.tight_layout()

    fig.savefig(args.output, dpi=150, bbox_inches="tight")
    print(f"saved: {args.output}")
    print(f"samples: {len(ys)}, "
          f"x range: {min(xs)}s ~ {max(xs)}s, "
          f"cpu min/avg/max: {min(ys)}m / {avg:.1f}m / {max(ys)}m")


if __name__ == "__main__":
    main()