// web/src/services/api.ts

// 🚨 VITE_WS_URL 환경변수를 사용하며, 로컬 개발 시 fallback 주소를 지정합니다.
// 루트 경로의 .env 파일에 VITE_WS_URL=ws://서버주소/rooms/ 를 선언해 주시면 됩니다.
export const WS_BASE_URL = import.meta.env.VITE_WS_URL || 'ws://localhost:8000';

// HTTP GET용 함수는 백엔드 요청에 따라 완전히 삭제했습니다!