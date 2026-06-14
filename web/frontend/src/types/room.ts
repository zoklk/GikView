export interface Room {
  id: string;
  name: string;
  building: 'A' | 'B';
  floor: number;
  isOccupied: boolean | null;   // null = WS state 수신 전(unknown) → 회색
}