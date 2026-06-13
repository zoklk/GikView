import React, { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { statusColor } from '../theme';
import type { Room } from '../types/room';
import structureSvg from '../assets/gikview-structure.svg?raw';

interface Props {
  rooms: Room[];
  isDarkMode: boolean;
}

const VB_W = 1864;
const VB_H = 880;
const B_CENTER_X = 395;
const A_CENTER_X = 1411;
const SVG_VW = 180;
const dongLeftVw = (centerX: number) => (centerX / VB_W) * SVG_VW;

const FLOORS = [
  { label: 'F3', frac: 98 / VB_H },
  { label: 'F2', frac: 431 / VB_H },
  { label: 'F1', frac: 763 / VB_H },
];

export const IsometricBuilding: React.FC<Props> = ({ rooms, isDarkMode }) => {
  const rootRef = useRef<HTMLDivElement>(null);
  const svgContainerRef = useRef<HTMLDivElement>(null);
  const [svgBox, setSvgBox] = useState({ top: 0, height: 0 });

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
          shape.style.fill = statusColor(room.isOccupied);
          shape.style.fillOpacity = '0.6';
          shape.style.transition = 'fill 0.3s ease';
        });
    });
  }, [rooms, isDarkMode]);

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
  }, []);

  return (
    <div ref={rootRef} className="relative w-full h-full pl-9">
      <div
        className="h-full overflow-x-auto overflow-y-hidden snap-x snap-mandatory"
        style={{ scrollbarWidth: 'none', msOverflowStyle: 'none', WebkitOverflowScrolling: 'touch' }}
      >
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
        `}</style>

        <div className="h-full w-[180vw] flex flex-col relative">
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

          <div
            ref={svgContainerRef}
            className="flex-1 min-h-0 flex items-center
              [&>svg]:w-full [&>svg]:h-auto [&>svg]:block [&>svg]:max-h-full
              [&>svg]:transition-all [&>svg]:duration-700 [&>svg]:ease-in-out
              [&_path]:cursor-pointer [&_rect]:cursor-pointer
            "
            dangerouslySetInnerHTML={{ __html: structureSvg }}
          />

          <div className="absolute top-0 left-0 h-full w-px snap-start pointer-events-none"></div>
          <div className="absolute top-0 right-0 h-full w-px snap-end pointer-events-none"></div>
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
