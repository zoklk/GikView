// src/mock/roomMock.ts
import type { Room } from '../types/room';
export const mockRooms: Room[] = [
  // A동 (구관) 1층
  { id: 'room-a1-community', name: '커뮤니티실', building: 'A', floor: 1, isOccupied: true },
  { id: 'room-a1-lounge', name: '학생휴게실', building: 'A', floor: 1, isOccupied: false },

  // A동 (구관) 2층
  { 
    id: 'room-a2-discussion', 
    name: '구관 토론실', 
    building: 'A', 
    floor: 2, 
    isOccupied: false, 
    description: 'GIST HOUSE에서 예약 후 사용' 
  },
  { id: 'room-a2-lounge', name: '학생휴게실', building: 'A', floor: 2, isOccupied: true },

  // A동 (구관) 3층
  { id: 'room-a3-lounge1', name: '학생 휴게실 1', building: 'A', floor: 3, isOccupied: false },
  { id: 'room-a3-lounge2', name: '학생 휴게실 2', building: 'A', floor: 3, isOccupied: false },
  { id: 'room-a3-reading', name: '노트북 열람실', building: 'A', floor: 3, isOccupied: true },

  // B동 (신관) 1층
  { id: 'room-b1-store', name: '신관 매점', building: 'B', floor: 1, isOccupied: true },

  // B동 (신관) 2층
  { id: 'room-b2-conf', name: '신관 2층 회의실', building: 'B', floor: 2, isOccupied: false },

  // B동 (신관) 3층
  { id: 'room-b3-conf', name: '신관 3층 회의실', building: 'B', floor: 3, isOccupied: false }
];