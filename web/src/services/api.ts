// web/src/services/api.ts
import type { Room } from '../types/room';

// 🚨 해결: 에러가 발생한 'axios'와 'API_BASE_URL' 선언을 완전히 삭제했습니다.

export const fetchRoomStatuses = async (): Promise<Room[]> => {
  // 현재는 Mock 데이터를 사용하므로, 실제 API 연동 시점에 axios를 다시 추가하면 됩니다.
  return []; 
};