"""
mpstat 로그 기반 노드 전체 CPU(usr+sys) 시계열 그래프 생성.

여러 mpstat 파일을 순서대로 이어 붙여 하나의 시계열로 그림. 파일 경계에
구분선과 라벨을 넣을 수 있어 "A 조건 vs B 조건" 비교에 적합.

로그 형식: `mpstat -P ALL 1 N` 표준 출력.
  `HH:MM:SS   all   usr   nice   sys   iowait   irq   soft   steal   guest   gnice   idle`

실행 예시:

  # testC: argocd scale=0 (baseline) vs scale=1 (load)
  python3 plot_node_cpu.py \
    --inputs ../raw/argoCD_load/testC_argocd_on_030319_mpstat.log ../raw/argoCD_load/testC_argocd_off_030648_mpstat.log \
    --segment-boundary 120 \
    --segment-labels "argocd running (baseline)" "argocd scaled to 0" \
    --title "Node CPU (usr+sys) - testC: Argo CD steady-state load" \
    --output ./testC_node_cpu.png
"""

import argparse
from pathlib import Path

import matplotlib.pyplot as plt


def parse_mpstat_cpu(path: Path) -> list[float]:
    """mpstat 로그에서 all 라인의 usr+sys 시계열을 % 단위로 반환."""
    series: list[float] = []
    with path.open() as f:
        for line in f:
            parts = line.split()
            if len(parts) < 12:
                continue
            # "HH:MM:SS all ..." 또는 "HH:MM:SS AM/PM all ..."
            if parts[1] == "all" or (len(parts) > 2 and parts[2] == "all"):
                try:
                    if ":" in parts[0]:
                        usr = float(parts[2])
                        sys = float(parts[4])
                        series.append(usr + sys)
                except (ValueError, IndexError):
                    continue
    return series


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", required=True, nargs="+", type=Path,
                        help="mpstat 로그 파일들 (순서대로 이어 붙임)")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--title", default="Node CPU (usr+sys) over time")
    parser.add_argument("--segment-boundary", type=int, default=None,
                        help="구분 수직선 위치(s)")
    parser.add_argument("--segment-labels", nargs="+", default=None,
                        help="각 구간 이름")
    parser.add_argument("--annotations", nargs="*", default=[],
                        help='"x:text" 형식 주석')
    args = parser.parse_args()

    # 파일별 파싱 및 이어붙이기 (1초당 1샘플 가정)
    xs: list[int] = []
    ys: list[float] = []
    segment_avgs: list[tuple[int, int, float]] = []  # (start, end, avg)
    for path in args.inputs:
        vals = parse_mpstat_cpu(path)
        if not vals:
            raise SystemExit(f"no mpstat samples parsed from {path}")
        start_x = len(xs)
        for v in vals:
            xs.append(len(xs))
            ys.append(v)
        end_x = len(xs) - 1
        segment_avgs.append((start_x, end_x, sum(vals) / len(vals)))

    fig, ax = plt.subplots(figsize=(10, 4.5))
    ax.plot(xs, ys, linewidth=1.4, color="#2e6bd6", label="usr+sys")

    # 구간별 평균선
    for start_x, end_x, avg in segment_avgs:
        ax.hlines(y=avg, xmin=start_x, xmax=end_x,
                  color="#888888", linestyle=":", linewidth=1.2)

    # 구분 수직선
    if args.segment_boundary is not None:
        ax.axvline(x=args.segment_boundary, color="#d94545",
                   linestyle="--", linewidth=1)

    # 구간 라벨 + 평균값 함께 표시
    if args.segment_labels:
        max_x = max(xs)
        if args.segment_boundary is not None:
            mids = [args.segment_boundary / 2,
                    args.segment_boundary + (max_x - args.segment_boundary) / 2]
        else:
            mids = [max_x / 2]
        ymax = max(ys)
        for (mid, label, (_, _, avg)) in zip(mids, args.segment_labels,
                                             segment_avgs):
            full_label = f"{label}\navg {avg:.1f}%"
            ax.text(mid, ymax * 1.02, full_label, ha="center", va="bottom",
                    fontsize=9, color="#333333",
                    bbox=dict(boxstyle="round,pad=0.3",
                              facecolor="white", edgecolor="#cccccc",
                              linewidth=0.5))

    # 주석
    for ann in args.annotations:
        x_str, text = ann.split(":", 1)
        x = int(x_str)
        if 0 <= x < len(ys):
            ax.annotate(
                text, xy=(x, ys[x]),
                xytext=(x + 8, ys[x] + 10),
                fontsize=9, color="#d94545",
                arrowprops=dict(arrowstyle="->", color="#d94545", lw=1),
            )

    ax.set_xlabel("Time (s)")
    ax.set_ylabel("CPU (%, usr+sys)")
    ax.set_title(args.title, fontsize=11)
    ax.set_ylim(bottom=0, top=max(ys) * 1.3)
    ax.grid(True, linestyle=":", alpha=0.4)
    ax.legend(loc="upper right", framealpha=0.95)
    fig.tight_layout()

    fig.savefig(args.output, dpi=150, bbox_inches="tight")
    print(f"saved: {args.output}")
    for (start_x, end_x, avg), path in zip(segment_avgs, args.inputs):
        print(f"  {path.name}: samples={end_x - start_x + 1}, avg={avg:.2f}%")


if __name__ == "__main__":
    main()