import React, { useEffect, useRef, useMemo } from 'react';
import { statusColor } from '../theme';
import type { Room } from '../types/room';
import figmaSvg from '../assets/floorplan.svg?raw';

interface Props {
  rooms: Room[];
  isDarkMode: boolean;
}

export const IsometricBuilding: React.FC<Props> = ({ rooms, isDarkMode }) => {
  const svgContainerRef = useRef<HTMLDivElement>(null);



  // 글자(#1E293B) path 를 잘라 </svg> 직전으로 이동 → 도형 위에 항상 표시.
  // F2 방은 SVG 파일에서 <g transform="translate(0 -14.75)"> 안 → 추출 시 transform
  // 잃으므로 F2 밴드(y 259~567) 텍스트만 동일 transform 으로 재포장해 정렬 유지.
  const focusedSvg = useMemo(() => {
    let processed = figmaSvg.replace(/viewBox="[^"]*"/, `viewBox="0 0 1864 831"`);
    const textElements = processed.match(/<path[^>]*fill="#1E293B"[^>]*\/>/g) || [];
    processed = processed.replace(/<path[^>]*fill="#1E293B"[^>]*\/>/g, '');
    const placedText = textElements.map((t) => {
      const m = t.match(/d="M[-0-9.]+ ([-0-9.]+)/);
      const y = m ? parseFloat(m[1]) : NaN;
      return y > 259.3 && y < 567.5
        ? `<g transform="translate(0 -14.75)">${t}</g>`
        : t;
    }).join('\n');
    processed = processed.replace('</svg>', placedText + '\n</svg>');
    return processed;
  }, []);

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
        // id 불일치 silent fail 방지: SVG id ↔ roomCatalog id 동기화 점검용
        console.warn(`[IsometricBuilding] SVG에서 방 id 미발견: #${room.id}`);
      }
    });
  }, [rooms, isDarkMode]); // 다크 토글 리렌더 후 inline fill 재적용

  return (
    <div 
      className="w-full h-full overflow-x-auto overflow-y-hidden snap-x snap-mandatory"
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

      {/* 2페이지 pager: 폭 180vw → 각 100vw 윈도우가 한 동+구름다리 표시 (겹침=구름다리) */}
      <div className="w-[180vw] h-full flex flex-col relative">
        {/* 동 라벨 헤더 (건물 위, 겹침 없음) */}
        <div className="shrink-0 w-full flex justify-between px-[8vw] pt-4 pb-2 pointer-events-none z-10">
          <h2 className="text-xl font-black text-[#1E293B] dark:text-white opacity-40 tracking-widest transition-colors">[ B동 (신관) ]</h2>
          <h2 className="text-xl font-black text-[#1E293B] dark:text-white opacity-40 tracking-widest transition-colors">[ A동 (구관) ]</h2>
        </div>

        {/* 구조도: 폭 100% (=180vw), 높이는 비율. 세로는 화면 안에 들어옴 */}
        <div
          ref={svgContainerRef}
          className="flex-1 min-h-0 flex items-center
            [&>svg]:w-full [&>svg]:h-auto [&>svg]:block [&>svg]:max-w-none
            [&>svg]:transition-all [&>svg]:duration-700 [&>svg]:ease-in-out
            [&_path]:transition-opacity [&_path]:cursor-pointer [&_path:hover]:opacity-70
            [&_rect]:transition-opacity [&_rect]:cursor-pointer [&_rect:hover]:opacity-70
          "
          dangerouslySetInnerHTML={{ __html: focusedSvg }}
        />

        {/* 스냅 앵커: 좌(B동 페이지) / 우(A동 페이지). dangerouslySetInnerHTML div 밖에 둠 */}
        <div className="absolute top-0 left-0 h-full w-px snap-start pointer-events-none"></div>
        <div className="absolute top-0 right-0 h-full w-px snap-end pointer-events-none"></div>
      </div>
    </div>
  );
};