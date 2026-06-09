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
