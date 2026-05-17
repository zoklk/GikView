export interface RoomStatus {
  roomId: string;       // 예: "ROOM_01"
  roomName: string;     // 예: "3층 스터디룸"
  isOccupied: boolean;  // 재실 여부 (true: 있음, false: 없음)
  updatedAt: string;    // ISO 8601 타임스탬프
}

export interface OccupancyHistory {
  id: string;
  roomId: string;
  status: 'ENTER' | 'LEAVE';
  timestamp: string;
}

// 브라우저가 이 파일을 정상적인 자바스크립트 모듈로 인식하게 강제하는 더미(Dummy) 변수
export const _MODULE_FIX = true;