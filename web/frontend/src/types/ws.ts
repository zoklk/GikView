// src/types/ws.ts
// 서버 → 클라이언트 WebSocket 메시지 포맷 (front-back-spec.md 메시지 포맷 참조)
export type WsMessage =
  | { type: 'state'; rooms: Record<string, boolean>; timestamp: string }
  | { type: 'pong' };
