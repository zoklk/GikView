// src/types/room.ts

export interface Room {
  id: string;
  name: string;
  building: 'A' | 'B';
  floor: number;
  isOccupied: boolean;
  description?: string;
}

export interface HistoryLog {
  timestamp: string;
  roomId: string;
  status: 'occupied' | 'cleared';
}