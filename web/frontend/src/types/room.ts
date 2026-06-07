// src/types/room.ts
export interface Room {
  id: string;
  name: string;
  building: 'A' | 'B';
  floor: number;
  isOccupied: boolean | null;
  description?: string;
}