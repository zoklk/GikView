// VITE_WS_URL 미설정 시 로컬 fallback (.env: VITE_WS_URL=ws://서버주소/rooms/)
export const WS_BASE_URL = import.meta.env.VITE_WS_URL || 'ws://localhost:8000';