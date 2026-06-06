// web/src/App.tsx
import { useState, useEffect, useRef } from 'react';
import { IntegratedBuilding } from './components/IntegratedBuilding';
import { IsometricBuilding } from './components/IsometricBuilding';
import { LoginPage } from './components/LoginPage';
import { WS_BASE_URL } from './services/api';
import { mockRooms } from './mock/roomMock'; // 🛠️ 베이스 데이터로 사용하기 위해 추가 임포트
import type { Room } from './types/room';

function App() {
  const [isAuthenticated, setIsAuthenticated] = useState(false);
  const [isDarkMode, setIsDarkMode] = useState(false);
  // 초기 상태는 mockRooms를 베이스로 사용합니다.
  const [rooms, setRooms] = useState<Room[]>(mockRooms);
  const [lastUpdated, setLastUpdated] = useState<string>('');
  
  // 타이머 메모리 누수 방지를 위한 Ref
  const pingIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    if (!isAuthenticated) return;

    let socket: WebSocket | null = null;

    const connectWebSocket = () => {
      socket = new WebSocket(WS_BASE_URL);

      socket.onopen = () => {
        console.log('✅ WebSocket 연결 수립 완료');
        
        // 1. 초기 상태 요청 (getState)
        socket?.send(JSON.stringify({ action: 'getState' }));

        // 2. Heartbeat (Ping) 설정: API GW Timeout(10분) 대비 8분(480초) 주기로 전송
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

          // 서버 응답 분기 처리
          if (data.type === 'pong') {
            // Ping에 대한 정상 응답 (로그 외 특별한 처리 불필요)
            return;
          }

          if (data.type === 'state' && data.rooms) {
            // 🚨 백엔드 객체 데이터 -> 프론트엔드 배열 데이터 병합 로직
            const updatedRooms = mockRooms.map((room) => {
              // 프론트엔드 ID(room-a-1)를 백엔드 Key(room_a_1) 포맷으로 임시 변환하여 매칭
              const backendKey = room.id.replace(/-/g, '_');
              
              return {
                ...room,
                // 백엔드 데이터에 해당 키가 존재하면 상태 반영, 없으면 기존 상태 유지
                isOccupied: data.rooms[backendKey] ?? room.isOccupied
              };
            });

            setRooms(updatedRooms);

            // 서버 제공 Timestamp 활용
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
        // Ping 인터벌 해제
        if (pingIntervalRef.current) clearInterval(pingIntervalRef.current);
        
        setTimeout(() => {
          if (isAuthenticated) connectWebSocket();
        }, 5000);
      };
    };

    connectWebSocket();

    return () => {
      if (pingIntervalRef.current) clearInterval(pingIntervalRef.current);
      if (socket) {
        socket.close();
      }
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