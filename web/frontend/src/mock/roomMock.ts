import type { Room } from '../types/room';

// 방 메타데이터(이름/층/동)만 보유. isOccupied 는 null 시드 → WS state 수신 전
// 회색(unknown) 렌더. 실제 점유는 백엔드 state 가 주입.
export const mockRooms: Room[] = [
  // A동 (구관)
  { id: 'room-a-1-community', name: '커뮤니티실', building: 'A', floor: 1, isOccupied: null },
  { id: 'room-a-1-lounge', name: '학생휴게실', building: 'A', floor: 1, isOccupied: null },
  { id: 'room-a-2-lounge', name: '하우스 라운지', building: 'A', floor: 2, isOccupied: null },
  { id: 'room-a-3-lounge1', name: '학생 휴게실 1', building: 'A', floor: 3, isOccupied: null },
  { id: 'room-a-3-lounge2', name: '학생 휴게실 2', building: 'A', floor: 3, isOccupied: null },
  { id: 'room-a-3-reading', name: '노트북 열람실', building: 'A', floor: 3, isOccupied: null },

  // B동 (신관)
  { id: 'room-b-1-store', name: '신관 매점', building: 'B', floor: 1, isOccupied: null },
  { id: 'room-b-2-meeting', name: '신관 2층 회의실', building: 'B', floor: 2, isOccupied: null },
  { id: 'room-b-3-meeting', name: '신관 3층 회의실', building: 'B', floor: 3, isOccupied: null }
];