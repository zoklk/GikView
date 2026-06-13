import React, { useEffect, useLayoutEffect, useRef, useMemo, useState } from 'react';
import { statusFill } from '../theme';
import type { Room } from '../types/room';
import structureSvg from '../assets/gikview-structure.svg?raw';

interface Props {
  rooms: Room[];
  isDarkMode: boolean;
}

const FLOOR_GAP = 150;
const VB_Y = 2 - FLOOR_GAP - 20;
const VB_H = 859 + FLOOR_GAP + 20 - VB_Y;

// SVG 가로 native 폭. 트랙 폭 = TRACK_VW vw → 한 동(폭 902)이 뷰포트에 거의 꽉차게.
const SVG_W = 1864;
const TRACK_VW = 181;
// 각 동 중심 x(native) → 트랙상 vw. snap-center 마커/라벨 위치 공용.
const B_CENTER_VW = (395 / SVG_W) * TRACK_VW;
const A_CENTER_VW = (1411 / SVG_W) * TRACK_VW;

const FLOORS = [
  { label: 'F3', frac: (98 - FLOOR_GAP - VB_Y) / VB_H },
  { label: 'F2', frac: (431 - VB_Y) / VB_H },
  { label: 'F1', frac: (763 + FLOOR_GAP - VB_Y) / VB_H },
];

export const IsometricBuilding: React.FC<Props> = ({ rooms, isDarkMode }) => {
  const rootRef = useRef<HTMLDivElement>(null);
  const svgContainerRef = useRef<HTMLDivElement>(null);
  const [svgBox, setSvgBox] = useState({ top: 0, height: 0 });

  // SVG 전처리(빌드타임 1회):
  //  - width/height 제거 → h-auto 가 viewBox 비율(1864:VB_H)을 따르게(아니면 native 880).
  //  - viewBox 를 층확대 후 콘텐츠에 맞춰 재설정.
  //  - 층 간격 확대: 직속 자식 id 접두(a-1-/a-2-/a-3-/b-1../room-a-3-)의 층번호로
  //    F3 위/F1 아래 translate 를 문자열에 baking. (DOM 변형은 React 의 innerHTML
  //    재주입으로 지워지므로 문자열에 박아야 생존. 직속 자식만 → 중첩 이중이동 없음.)
  const svgMarkup = useMemo(() => {
    const doc = new DOMParser().parseFromString(structureSvg, 'image/svg+xml');
    const svg = doc.documentElement;
    svg.removeAttribute('width');
    svg.removeAttribute('height');
    svg.setAttribute('viewBox', `0 ${VB_Y} ${SVG_W} ${VB_H}`);
    Array.from(svg.children).forEach((el) => {
      const m = /^(?:room-)?[ab]-([123])(?:-|$)/.exec(el.id);
      if (!m) return;
      const d = (2 - Number(m[1])) * FLOOR_GAP; // F3→-G, F2→0, F1→+G
      if (!d) return;
      const prev = el.getAttribute('transform');
      el.setAttribute('transform', `translate(0 ${d})${prev ? ' ' + prev : ''}`);
    });
    return new XMLSerializer().serializeToString(svg);
  }, []);

  useEffect(() => {
    const svgEl = svgContainerRef.current?.querySelector('svg');
    if (!svgEl || rooms.length === 0) return;
    rooms.forEach((room) => {
      svgEl
        .querySelectorAll<SVGGraphicsElement>(`[id="${room.id}"], [id^="${room.id}_"]`)
        .forEach((node) => {
          const shape =
            node.tagName.toLowerCase() === 'g'
              ? node.querySelector<SVGGraphicsElement>(
                  'path[stroke]:not([fill]), rect[stroke]:not([fill])',
                )
              : node;
          if (!shape) return;
          shape.style.fill = statusFill(room.isOccupied, isDarkMode);
          shape.style.fillOpacity = '1';
          shape.style.transition = 'fill 0.3s ease';
        });
    });
  }, [rooms, isDarkMode]);

  // 층 라벨(F1/F2/F3) 위치 계산용으로 렌더된 svg 의 top/height 측정.
  // svg 가 commit 직후 없을 수 있어 RO 로 재시도.
  useLayoutEffect(() => {
    let observingSvg = false;
    const measure = () => {
      const svg = svgContainerRef.current?.querySelector('svg');
      const root = rootRef.current;
      if (!svg || !root) return;
      if (!observingSvg) {
        ro.observe(svg);
        observingSvg = true;
      }
      const s = svg.getBoundingClientRect();
      const r = root.getBoundingClientRect();
      setSvgBox({ top: s.top - r.top, height: s.height });
    };
    const ro = new ResizeObserver(measure);
    measure();
    if (rootRef.current) ro.observe(rootRef.current);
    return () => ro.disconnect();
  }, []);

  return (
    <div ref={rootRef} className="relative w-full h-full pl-9">
      <div
        className="h-full overflow-x-auto overflow-y-hidden snap-x snap-mandatory pr-3"
        style={{ scrollbarWidth: 'none', msOverflowStyle: 'none', WebkitOverflowScrolling: 'touch' }}
      >
        <style>{`
          svg [stroke="black"] { stroke: #94A3B8; }
          .dark svg [stroke="black"] { stroke: #64748B; }
          svg path[mask] { fill: #94A3B8; }
          .dark svg path[mask] { fill: #64748B; }
          .dark svg path[fill="black"]:not([mask]) { fill: #F8FAFC; }
          svg path[fill="black"]:not([mask]) { transform-box: fill-box; transform-origin: center; transform: scale(1.3); }
          svg rect[fill="#F5F5F5"] { fill: transparent; }
          .dark svg rect[fill="#F5F5F5"] { fill: var(--surface-from); }
          svg path[fill="white"] { fill: var(--surface-from); }
          svg path, svg rect { transition: fill 0.3s ease, stroke 0.3s ease, opacity 0.2s ease; }
        `}</style>

        <div className="h-full flex flex-col relative" style={{ width: `${TRACK_VW}vw` }}>
          <div className="shrink-0 relative pt-4 pb-2 pointer-events-none z-10">
            <span className="block text-xl font-black invisible">A동</span>
            <h2
              style={{ left: `${B_CENTER_VW}vw` }}
              className="absolute top-4 -translate-x-1/2 text-xl font-black text-[#1E293B] dark:text-white opacity-40 tracking-widest transition-colors"
            >
              B동
            </h2>
            <h2
              style={{ left: `${A_CENTER_VW}vw` }}
              className="absolute top-4 -translate-x-1/2 text-xl font-black text-[#1E293B] dark:text-white opacity-40 tracking-widest transition-colors"
            >
              A동
            </h2>
          </div>

          <div
            ref={svgContainerRef}
            className="flex-1 min-h-0 flex items-start
              [&>svg]:w-full [&>svg]:h-auto [&>svg]:block
              [&>svg]:transition-all [&>svg]:duration-700 [&>svg]:ease-in-out
              [&_path]:cursor-pointer [&_rect]:cursor-pointer
            "
            dangerouslySetInnerHTML={{ __html: svgMarkup }}
          />

          {/* 동 중심에 snap-center 마커 → 스와이프 시 각 동이 뷰포트 가로 중앙 정렬 */}
          <div
            style={{ left: `${B_CENTER_VW}vw` }}
            className="absolute top-0 h-full w-px snap-center pointer-events-none"
          ></div>
          <div
            style={{ left: `${A_CENTER_VW}vw` }}
            className="absolute top-0 h-full w-px snap-center pointer-events-none"
          ></div>
        </div>
      </div>

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
