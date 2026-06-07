// src/mock/roomMock.ts
import type { Room } from '../types/room';

export const mockRooms: Room[] = [
  // A동 (구관) - 제가 1단계에서 코드에 박아넣은 ID와 일치시켰습니다.
  { id: 'room-a-1-community', name: '커뮤니티실', building: 'A', floor: 1, isOccupied: true },
  { id: 'room-a-1-lounge', name: '학생휴게실', building: 'A', floor: 1, isOccupied: false },
  { id: 'room-a-2-lounge', name: '하우스 라운지', building: 'A', floor: 2, isOccupied: true },
  { id: 'room-a-3-lounge1', name: '학생 휴게실 1', building: 'A', floor: 3, isOccupied: false },
  { id: 'room-a-3-lounge2', name: '학생 휴게실 2', building: 'A', floor: 3, isOccupied: false },
  { id: 'room-a-3-reading', name: '노트북 열람실', building: 'A', floor: 3, isOccupied: true },

  // B동 (신관)
  { id: 'room-b-1-store', name: '신관 매점', building: 'B', floor: 1, isOccupied: true },
  { id: 'room-b-2-meeting', name: '신관 2층 회의실', building: 'B', floor: 2, isOccupied: false },
  { id: 'room-b-3-meeting', name: '신관 3층 회의실', building: 'B', floor: 3, isOccupied: false }
];
// ID 규격 통일 및 예약 공간(토론실, 해동) 삭제 완료