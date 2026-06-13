// 재실 상태 색상 단일 진실원천. SVG inline fill(JS) 과 범례(legend)가 공유.
// CSS 토큰(index.css --color-free/occupied/unknown)과 값 일치 유지.
import type { Room } from './types/room';

export const STATUS = {
  free: '#34C9A0', // 미점유
  occupied: '#F08489', // 점유
  unknown: '#9FB0C3', // WS state 수신 전
} as const;

/** isOccupied(boolean|null) → fill 색 */
export const statusColor = (isOccupied: Room['isOccupied']): string =>
  isOccupied === null ? STATUS.unknown : isOccupied ? STATUS.occupied : STATUS.free;

// 상태색을 베이스 위로 블렌드한 solid. 라이트=흰 베이스(파스텔), 다크=어두운 베이스
// (밝게 글레어하지 않고 라이트와 비슷한 통합 톤). 맵 방 채움 전용.
const hexRgb = (hex: string): [number, number, number] => {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
};
const blend = (hex: string, base: [number, number, number], a: number): string => {
  const [r, g, b] = hexRgb(hex);
  const m = (c: number, bc: number) => Math.round(c * a + bc * (1 - a));
  return `rgb(${m(r, base[0])}, ${m(g, base[1])}, ${m(b, base[2])})`;
};

export const statusFill = (isOccupied: Room['isOccupied'], isDark: boolean): string =>
  isDark
    ? blend(statusColor(isOccupied), [15, 26, 46], 0.72) // 다크 표면(surface-to) 위
    : blend(statusColor(isOccupied), [255, 255, 255], 0.6); // 흰 위 파스텔
