import React, { useEffect, useLayoutEffect, useRef, useMemo, useState } from 'react';
import { statusColor } from '../theme';
import type { Room } from '../types/room';
import figmaSvg from '../assets/floorplan.svg?raw';

interface Props {
  rooms: Room[];
  isDarkMode: boolean;
}

// 모바일 전용 층 간격 추가 이동량(viewBox 단위). 데스크탑은 원본 그대로 두고,
// 모바일만 F3 위로 / F1 아래로 밀어 층간 여백을 키운다(비왜곡 = 도형 크기 유지).
const FLOOR_GAP = 110;
// viewBox 상하 여유. 층 이동분(FLOOR_GAP) + 도형 높이(±96) 를 담고 약간의 패딩.
const VB_PAD = 30;
const VB_MIN_Y = -(FLOOR_GAP + VB_PAD);
const VB_HEIGHT = 831 + 2 * (FLOOR_GAP + VB_PAD);

// 좌우 여백(viewBox 단위). A동 우측이 화면 끝에 붙지 않도록 캔버스를 양옆으로 확장.
const VB_PAD_X = 100;
const VB_MIN_X = -VB_PAD_X;
const VB_WIDTH = 1864 + 2 * VB_PAD_X;

// svg 가 차지하는 가로 폭(vw). 2페이지 pager 기준.
const SVG_VW = 180;
// 건물 중심 x(원본 좌표) → svg 좌측 기준 vw. 동 라벨을 건물 중심선에 배치.
const dongLeftVw = (centerX: number) => ((centerX - VB_MIN_X) / VB_WIDTH) * SVG_VW;
const B_CENTER_X = (1.667 + 788.66) / 2; // ≈ 395
const A_CENTER_X = (959.5 + 1862) / 2; // ≈ 1411

// 층 밴드 y중심(원본 viewBox) → 모바일 이동 후 → 새 viewBox 높이비율.
// 원본 중심: F3 98 / F2 406 / F1 714 (floorplan.svg b-3/b-2/b-1 외곽 기준).
const FLOORS = [
  { label: 'F3', center: 98 - FLOOR_GAP },
  { label: 'F2', center: 406 },
  { label: 'F1', center: 714 + FLOOR_GAP },
].map((f) => ({ label: f.label, frac: (f.center - VB_MIN_Y) / VB_HEIGHT }));

export const IsometricBuilding: React.FC<Props> = ({ rooms, isDarkMode }) => {
  const rootRef = useRef<HTMLDivElement>(null);
  const svgContainerRef = useRef<HTMLDivElement>(null);
  // 실제 렌더된 svg 의 root 기준 세로 위치/높이. 층 라벨을 px 로 정밀 정렬.
  const [svgBox, setSvgBox] = useState({ top: 0, height: 0 });

  // 모바일 전용 가공: id 가 인코딩한 층(a-2-*, b-3, room-a-3-*, a-1-door…)별로
  // background/rooms/door 직속 자식을 vertical translate → 층 간격 확대.
  // preserveAspectRatio=meet(기본) 유지 → 도형 왜곡 없음. viewBox 상하 확장.
  const focusedSvg = useMemo(() => {
    const doc = new DOMParser().parseFromString(figmaSvg, 'image/svg+xml');
    const svg = doc.querySelector('svg');
    if (!svg) return figmaSvg;

    svg.setAttribute('viewBox', `${VB_MIN_X} ${VB_MIN_Y} ${VB_WIDTH} ${VB_HEIGHT}`);
    svg.removeAttribute('width');
    svg.removeAttribute('height');

    // id 의 층 숫자 → 이동량. 매칭 없으면(bridge 등) 0(F2 취급, 안 움직임).
    const deltaOf = (id: string): number => {
      const m = id.match(/[ab]-([123])/);
      if (!m) return 0;
      return m[1] === '3' ? -FLOOR_GAP : m[1] === '1' ? FLOOR_GAP : 0;
    };

    ['background', 'rooms', 'door'].forEach((cid) => {
      const container = doc.querySelector(`[id="${cid}"]`);
      if (!container) return;
      Array.from(container.children).forEach((el) => {
        const d = deltaOf(el.getAttribute('id') || '');
        if (!d) return;
        // 기존 transform(F2 의 -14.75 등) 앞에 층 이동을 합성.
        const prev = el.getAttribute('transform');
        el.setAttribute('transform', `translate(0 ${d})${prev ? ' ' + prev : ''}`);
      });
    });

    return new XMLSerializer().serializeToString(svg);
  }, []);

  // 방 점유 색 주입 (id 는 가공 후에도 보존).
  useEffect(() => {
    if (!svgContainerRef.current || rooms.length === 0) return;
    const svgEl = svgContainerRef.current.querySelector('svg');
    if (!svgEl) return;

    rooms.forEach((room) => {
      const roomElement = svgEl.querySelector(`#${room.id}`) as SVGGraphicsElement;
      if (roomElement) {
        roomElement.style.fill = statusColor(room.isOccupied);
        roomElement.style.fillOpacity = '0.6';
        roomElement.style.transition = 'fill 0.3s ease';
      } else if (import.meta.env.DEV) {
        console.warn(`[IsometricBuilding] SVG에서 방 id 미발견: #${room.id}`);
      }
    });
  }, [rooms, isDarkMode]);

  // 렌더된 svg 의 세로 위치·높이 실측 → 층 라벨 정렬. 가로 스크롤은 세로에 영향
  // 없으므로 슬라이드해도 라벨 고정. 리사이즈/방향전환 시 갱신.
  useLayoutEffect(() => {
    const measure = () => {
      const svg = svgContainerRef.current?.querySelector('svg');
      const root = rootRef.current;
      if (!svg || !root) return;
      const s = svg.getBoundingClientRect();
      const r = root.getBoundingClientRect();
      setSvgBox({ top: s.top - r.top, height: s.height });
    };
    measure();
    const svg = svgContainerRef.current?.querySelector('svg');
    const ro = new ResizeObserver(measure);
    if (svg) ro.observe(svg);
    if (rootRef.current) ro.observe(rootRef.current);
    return () => ro.disconnect();
  }, [focusedSvg]);

  return (
    <div ref={rootRef} className="relative w-full h-full pl-9">
      {/* 슬라이드되는 건물(가로 스크롤). 동 라벨은 내부라 함께 슬라이드. */}
      <div
        className="h-full overflow-x-auto overflow-y-hidden snap-x snap-mandatory"
        style={{ scrollbarWidth: 'none', msOverflowStyle: 'none', WebkitOverflowScrolling: 'touch' }}
      >
        <style>{`
          .dark svg path[stroke="#94A3B8"] { stroke: #64748B !important; }
          .dark svg rect[stroke="#94A3B8"] { stroke: #64748B !important; }
          .dark svg path[fill="#1E293B"] { fill: #F8FAFC !important; }
          .dark svg rect[fill="#1E293B"] { fill: #F8FAFC !important; }
          /* door: figma 투명→1층 선 비침 방지용 회색을 배경색으로 칠해 숨김 (라이트/다크 자동) */
          svg path[fill="#D9D9D9"], svg rect[fill="#D9D9D9"] { fill: var(--surface-to) !important; }
          svg path, svg rect { transition: fill 0.3s ease, stroke 0.3s ease, opacity 0.2s ease !important; }
        `}</style>

        {/* w-[180vw]: 넓은 쪽(A동, 폭 902)이 한 화면(≈viewBox 1036)에 여유롭게 들어옴.
            2페이지 pager → snap 으로 B동 / A동. svg 는 자연비율(meet)이라 세로는
            화면을 꽉 채우지 않고 약간의 위아래 여백을 남김. */}
        <div className="h-full w-[180vw] flex flex-col relative">
          {/* 동 라벨 헤더 (건물 위). 각 건물 중심선(x)에 정렬, 건물과 함께 슬라이드.
              invisible span 으로 밴드 높이만 확보하고 라벨은 절대배치. */}
          <div className="shrink-0 relative pt-4 pb-2 pointer-events-none z-10">
            <span className="block text-xl font-black invisible">A동</span>
            <h2
              style={{ left: `${dongLeftVw(B_CENTER_X)}vw` }}
              className="absolute top-4 -translate-x-1/2 text-xl font-black text-[#1E293B] dark:text-white opacity-40 tracking-widest transition-colors"
            >
              B동
            </h2>
            <h2
              style={{ left: `${dongLeftVw(A_CENTER_X)}vw` }}
              className="absolute top-4 -translate-x-1/2 text-xl font-black text-[#1E293B] dark:text-white opacity-40 tracking-widest transition-colors"
            >
              A동
            </h2>
          </div>

          {/* 구조도: 폭 100%(=180vw), 높이는 비율(meet) → 세로 가운데 정렬. */}
          <div
            ref={svgContainerRef}
            className="flex-1 min-h-0 flex items-center
              [&>svg]:w-full [&>svg]:h-auto [&>svg]:block [&>svg]:max-h-full
              [&>svg]:transition-all [&>svg]:duration-700 [&>svg]:ease-in-out
              [&_path]:transition-opacity [&_path]:cursor-pointer [&_path:hover]:opacity-70
              [&_rect]:transition-opacity [&_rect]:cursor-pointer [&_rect:hover]:opacity-70
            "
            dangerouslySetInnerHTML={{ __html: focusedSvg }}
          />

          {/* 스냅 앵커: 좌(B동) / 우(A동) */}
          <div className="absolute top-0 left-0 h-full w-px snap-start pointer-events-none"></div>
          <div className="absolute top-0 right-0 h-full w-px snap-end pointer-events-none"></div>
        </div>
      </div>

      {/* 좌측 고정 층 라벨: 스크롤 컨테이너 밖 → 가로 슬라이드 영향 없음.
          실측한 svg 세로 위치/높이에 층 밴드 비율을 곱해 px 정렬. */}
      <div className="pointer-events-none absolute left-0 top-0 w-9 select-none">
        {svgBox.height > 0 &&
          FLOORS.map((f) => (
            <span
              key={f.label}
              style={{ top: svgBox.top + f.frac * svgBox.height }}
              className="absolute inset-x-0 -translate-y-1/2 text-center text-sm font-black text-[#1E293B] dark:text-white opacity-40 tracking-wider transition-colors"
            >
              {f.label}
            </span>
          ))}
      </div>
    </div>
  );
};
