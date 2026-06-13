import React, { useEffect, useRef, useMemo } from 'react';
import { statusColor } from '../theme';
import type { Room } from '../types/room';
import structureSvg from '../assets/gikview-structure.svg?raw';

interface Props {
  rooms: Room[];
  isDarkMode: boolean;
}

const VIEWBOX = '-150 -95 2070 1035';

const OVERLAY = `
  <g pointer-events="none" text-anchor="middle" font-family="Pretendard, sans-serif">
    <text class="map-dong"  x="395"  y="-46" font-size="46" font-weight="800" letter-spacing="6">B동</text>
    <text class="map-dong"  x="1411" y="-46" font-size="46" font-weight="800" letter-spacing="6">A동</text>
    <text class="map-floor" x="-80"  y="113" font-size="46" font-weight="800" letter-spacing="2">F3</text>
    <text class="map-floor" x="-80"  y="446" font-size="46" font-weight="800" letter-spacing="2">F2</text>
    <text class="map-floor" x="-80"  y="778" font-size="46" font-weight="800" letter-spacing="2">F1</text>
  </g>`;

export const IntegratedBuilding: React.FC<Props> = ({ rooms, isDarkMode }) => {
  const ref = useRef<HTMLDivElement>(null);

  const svgMarkup = useMemo(
    () =>
      structureSvg
        .replace(/viewBox="[^"]*"/, `viewBox="${VIEWBOX}"`)
        .replace('</svg>', `${OVERLAY}</svg>`),
    [],
  );

  useEffect(() => {
    const svgEl = ref.current?.querySelector('svg');
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
          shape.style.fill = statusColor(room.isOccupied);
          shape.style.fillOpacity = '0.6';
          shape.style.transition = 'fill 0.3s ease';
        });
    });
  }, [rooms, isDarkMode]);

  return (
    <div className="w-full h-full flex justify-center items-center p-2 md:p-3 overflow-hidden bg-transparent">
      <style>{`
        svg [stroke="black"] { stroke: #94A3B8; }
        .dark svg [stroke="black"] { stroke: #64748B; }
        svg path[mask] { fill: #94A3B8; }
        .dark svg path[mask] { fill: #64748B; }
        .dark svg path[fill="black"]:not([mask]) { fill: #F8FAFC; }
        svg path[fill="black"]:not([mask]) { transform-box: fill-box; transform-origin: center; transform: scale(1.3); }
        svg rect[fill="#F5F5F5"] { fill: var(--surface-from); }
        svg path[fill="white"] { fill: var(--surface-from); }
        svg path, svg rect { transition: fill 0.3s ease, stroke 0.3s ease, opacity 0.2s ease; }
        .map-dong  { fill: #334155; opacity: 0.8; transition: fill 0.3s ease; }
        .map-floor { fill: #475569; opacity: 0.6; transition: fill 0.3s ease; }
        .dark .map-dong  { fill: #E2E8F0; opacity: 0.85; }
        .dark .map-floor { fill: #CBD5E1; opacity: 0.65; }
      `}</style>

      <div
        ref={ref}
        className="w-full h-full max-w-none flex justify-center items-center
          [&>svg]:max-w-full [&>svg]:max-h-full [&>svg]:w-auto [&>svg]:h-auto [&>svg]:block
          [&>svg]:transition-all [&>svg]:duration-700 [&>svg]:ease-in-out
          [&_path]:cursor-pointer [&_rect]:cursor-pointer"
        dangerouslySetInnerHTML={{ __html: svgMarkup }}
      />
    </div>
  );
};
