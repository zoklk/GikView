// src/types/room.ts
export interface Room {
  id: string;
  name: string;
  building: 'A' | 'B';
  floor: number;
  isOccupied: boolean;
  description?: string;
}
// HistoryLog 인터페이스 삭제 완료