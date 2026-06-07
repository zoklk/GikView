// web/frontend/src/App.tsx
import { useState, useEffect, useRef } from 'react';
import { IntegratedBuilding } from './components/IntegratedBuilding';
import { IsometricBuilding } from './components/IsometricBuilding';
import { LoginPage } from './components/LoginPage';
import { WS_BASE_URL } from './services/api';
import type { Room } from './types/room';

// 🚨 선배님 피드백 반영: 외부 Mock 파일 의존성을 완전히 제거하고 내부에 뼈대 데이터를 직접 선언.
// 올려주신 A동/B동 오리지널 데이터를 기반으로 구성했으며, 초기 상태는 모두 false입니다.
const INITIAL_ROOMS: Room[] = [
  { id: 'room-a-1-community', name: '커뮤니티실', building: 'A', floor: 1, isOccupied: null },
  { id: 'room-a-1-lounge', name: '학생휴게실', building: 'A', floor: 1, isOccupied: null },
  { id: 'room-a-2-lounge', name: '하우스 라운지', building: 'A', floor: 2, isOccupied: null },
  { id: 'room-a-3-lounge1', name: '학생 휴게실 1', building: 'A', floor: 3, isOccupied: null },
  { id: 'room-a-3-lounge2', name: '학생 휴게실 2', building: 'A', floor: 3, isOccupied: null },
  { id: 'room-a-3-reading', name: '노트북 열람실', building: 'A', floor: 3, isOccupied: null },
  { id: 'room-b-1-store', name: '신관 매점', building: 'B', floor: 1, isOccupied: null },
  { id: 'room-b-2-meeting', name: '신관 2층 회의실', building: 'B', floor: 2, isOccupied: null },
  { id: 'room-b-3-meeting', name: '신관 3층 회의실', building: 'B', floor: 3, isOccupied: null }
];

function App() {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isDarkMode, setIsDarkMode] = useState(false); // 상태 고정 해제: 새로고침 시 무조건 라이트 모드

  const [rooms, setRooms] = useState<Room[]>(INITIAL_ROOMS);
  const [lastUpdated, setLastUpdated] = useState<string>('');
  
  const pingIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    if (!isAuthenticated) return;

    let socket: WebSocket | null = null;

    const connectWebSocket = () => {
      socket = new WebSocket(WS_BASE_URL);

      socket.onopen = () => {
        console.log('✅ WebSocket 연결 수립 완료');
        socket?.send(JSON.stringify({ action: 'getState' }));

        const EIGHT_MINUTES = 8 * 60 * 1000;
        pingIntervalRef.current = setInterval(() => {
          if (socket?.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({ action: 'ping' }));
          }
        }, EIGHT_MINUTES);
      };

      socket.onmessage = (event) => {
        try {
          const data = JSON.parse(event.data);

          if (data.type === 'pong') return;

          if (data.type === 'state' && data.rooms) {
            // 🚨 백엔드 키 규격(room_a_1_community)을 프론트엔드 규격(room-a-1-community)에 매핑하여 동기화
            setRooms(prevRooms => prevRooms.map(room => {
              const backendKey = room.id.replace(/-/g, '_');
              return {
                ...room,
                isOccupied: data.rooms[backendKey] ?? room.isOccupied
              };
            }));

            if (data.timestamp) {
              const date = new Date(data.timestamp);
              setLastUpdated(
                `${date.getHours().toString().padStart(2, '0')}:${date.getMinutes().toString().padStart(2, '0')}:${date.getSeconds().toString().padStart(2, '0')}`
              );
            }
          }
        } catch (error) {
          console.error('❌ WebSocket 메시지 파싱 오류:', error);
        }
      };

      socket.onerror = (error) => {
        console.error('❌ WebSocket 통신 오류:', error);
      };

      socket.onclose = () => {
        console.log('🔌 WebSocket 연결 종료. 5초 후 재연결 시도...');
        if (pingIntervalRef.current) clearInterval(pingIntervalRef.current);
        
        setTimeout(() => {
          if (isAuthenticated) connectWebSocket();
        }, 5000);
      };
    };

    connectWebSocket();

    return () => {
      if (pingIntervalRef.current) clearInterval(pingIntervalRef.current);
      if (socket) socket.close();
    };
  }, [isAuthenticated]);

  if (!isAuthenticated) {
    return <LoginPage onLogin={() => setIsAuthenticated(true)} />;
  }

  return (
    <div className={`h-screen w-screen overflow-hidden flex flex-col font-sans select-none transition-colors duration-300 ${isDarkMode ? 'dark bg-[#0F172A]' : 'bg-[#F7F9FB]'}`}>
      <header className="flex justify-between items-center p-4 md:p-6 bg-[#FFFFFF] dark:bg-[#1E293B] border-b-4 border-[#1F7A8C] z-20 shrink-0 shadow-sm transition-colors duration-300">
        <div className="flex items-center gap-3">
          <button 
            onClick={() => setIsDarkMode(!isDarkMode)}
            className="p-2 rounded-full bg-gray-100 dark:bg-gray-700 shadow-sm border border-gray-200 dark:border-gray-600 active:scale-95 transition-transform"
          >
            {isDarkMode ? '🌙' : '☀️'}
          </button>
          <div className="flex items-center gap-1.5 text-xs font-bold text-gray-500 dark:text-gray-400">
            <span className="relative flex h-2 w-2">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-[#2EBFA5] opacity-75"></span>
              <span className="relative inline-flex rounded-full h-2 w-2 bg-[#2EBFA5]"></span>
            </span>
            Updated {lastUpdated || 'Loading...'}
          </div>
        </div>

        <div className="flex flex-col items-end">
          <h1 className="text-4xl md:text-5xl font-black italic tracking-tighter uppercase leading-none text-[#1E293B] dark:text-white transition-colors duration-300">
            GikView
          </h1>
          <div className="h-2 w-full bg-[#1F7A8C] mt-2"></div>
        </div>
      </header>

      <main className="flex-1 w-full h-full relative overflow-hidden">
        <div className="md:hidden w-full h-full relative">
          <IsometricBuilding rooms={rooms} />
        </div>
        <div className="hidden md:flex w-full h-full">
          <IntegratedBuilding rooms={rooms} />
        </div>
      </main>
    </div>
  );
}

export default App;