import React, { useEffect, useRef, useMemo } from 'react';
import { statusColor } from '../theme';
import type { Room } from '../types/room';
import figmaSvg from '../assets/floorplan.svg?raw';

interface Props {
  rooms: Room[];
  isDarkMode: boolean;
}

export const IntegratedBuilding: React.FC<Props> = ({ rooms, isDarkMode }) => {
  const svgContainerRef = useRef<HTMLDivElement>(null);



  // 글자(#1E293B) path 를 잘라 </svg> 직전으로 이동 → 도형 위에 항상 표시.
  // + 동(상단)·층(중앙 빈 공간) 라벨을 SVG 좌표계에 주입 → 도형과 완벽 정렬/스케일.
  // viewBox 상단을 80 확장해 동 라벨 자리 확보. 층 밴드 y중심: 3층 98 / 2층 420 / 1층 713.
  const focusedSvg = useMemo(() => {
    // viewBox 좌측 150·상단 90 확장 → 층 라벨(좌측 거터)·동 라벨(상단) 자리 확보.
    // 동 중심 x: B동 421 / A동 1407. 층 밴드 y중심: F3 98 / F2 420 / F1 713.
    let processed = figmaSvg.replace(/viewBox="[^"]*"/, `viewBox="-150 -90 2014 921"`);
    const textElements = processed.match(/<path[^>]*fill="#1E293B"[^>]*\/>/g) || [];
    processed = processed.replace(/<path[^>]*fill="#1E293B"[^>]*\/>/g, '');

    // 텍스트를 도형 위(z-order)로 빼면서 top-level 로 옮기면, SVG 파일에서 F2 방
    // <g transform="translate(0 -14.75)"> 안에 있던 텍스트가 transform 을 잃는다.
    // → F2 밴드(y 259~567)에 속한 텍스트만 동일 transform 으로 다시 감싸 정렬 유지.
    const placedText = textElements.map((t) => {
      const m = t.match(/d="M[-0-9.]+ ([-0-9.]+)/);
      const y = m ? parseFloat(m[1]) : NaN;
      return y > 259.3 && y < 567.5
        ? `<g transform="translate(0 -14.75)">${t}</g>`
        : t;
    }).join('\n');

    const overlay = `
      <g pointer-events="none" text-anchor="middle" font-family="Pretendard, sans-serif">
        <text class="map-dong"  x="421"  y="-46" font-size="46" font-weight="800" letter-spacing="6">B동</text>
        <text class="map-dong"  x="1407" y="-46" font-size="46" font-weight="800" letter-spacing="6">A동</text>
        <text class="map-floor" x="-75" y="113" font-size="46" font-weight="800" letter-spacing="2">F3</text>
        <text class="map-floor" x="-75" y="421" font-size="46" font-weight="800" letter-spacing="2">F2</text>
        <text class="map-floor" x="-75" y="728" font-size="46" font-weight="800" letter-spacing="2">F1</text>
      </g>`;

    processed = processed.replace('</svg>', placedText + overlay + '\n</svg>');
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
        console.warn(`[IntegratedBuilding] SVG에서 방 id 미발견: #${room.id}`);
      }
    });
  }, [rooms, isDarkMode]); // 다크 토글 리렌더 후 inline fill 재적용

  return (
    <div className="w-full h-full flex justify-center items-center p-8 overflow-hidden bg-transparent">
      
      <style>{`
        .dark svg path[stroke="#94A3B8"] { stroke: #64748B !important; }
        .dark svg rect[stroke="#94A3B8"] { stroke: #64748B !important; }
        .dark svg path[fill="#1E293B"] { fill: #F8FAFC !important; }
        .dark svg rect[fill="#1E293B"] { fill: #F8FAFC !important; }
        /* door: figma 투명→1층 선 비침 방지용 회색을 배경색으로 칠해 숨김 (라이트/다크 자동) */
        svg path[fill="#D9D9D9"], svg rect[fill="#D9D9D9"] { fill: var(--surface-to) !important; }
        svg path, svg rect { transition: fill 0.3s ease, stroke 0.3s ease, opacity 0.2s ease !important; }
        /* 동(상단)·층(좌측) 라벨: 또렷하되 도형보다 약하게, 다크 대응 */
        .map-dong  { fill: #334155; opacity: 0.8; transition: fill 0.3s ease; }
        .map-floor { fill: #475569; opacity: 0.6; transition: fill 0.3s ease; }
        .dark .map-dong  { fill: #E2E8F0; opacity: 0.85; }
        .dark .map-floor { fill: #CBD5E1; opacity: 0.65; }
      `}</style>

      <div 
        ref={svgContainerRef}
        className="w-full h-full max-w-[1800px] flex justify-center items-center drop-shadow-sm
          [&>svg]:max-w-full [&>svg]:max-h-full [&>svg]:w-auto [&>svg]:h-auto [&>svg]:block
          [&>svg]:transition-all [&>svg]:duration-700 [&>svg]:ease-in-out
          [&_path]:transition-opacity [&_path]:cursor-pointer [&_path:hover]:opacity-70
          [&_rect]:transition-opacity [&_rect]:cursor-pointer [&_rect:hover]:opacity-70
        "
        dangerouslySetInnerHTML={{ __html: focusedSvg }}
      />
    </div>
  );
};