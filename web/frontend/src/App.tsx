import { useState, useEffect, useRef } from 'react';
import type { User } from 'oidc-client-ts';
import { IntegratedBuilding } from './components/IntegratedBuilding';
import { IsometricBuilding } from './components/IsometricBuilding';
import { LoginPage } from './components/LoginPage';
import { WS_BASE_URL } from './services/api';
import { authService } from './services/auth';
import { roomCatalog } from './data/roomCatalog'; // 방 메타데이터(이름/층/동) 베이스
import type { Room } from './types/room';
import type { WsMessage } from './types/ws';

const pad = (n: number) => n.toString().padStart(2, '0');

function App() {
  const [user, setUser] = useState<User | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [isDarkMode, setIsDarkMode] = useState(false);
  const [rooms, setRooms] = useState<Room[]>(roomCatalog);
  const [lastUpdated, setLastUpdated] = useState<string>('');

  // StrictMode 이중 마운트 시 callback 중복 교환 방지
  const bootstrappedRef = useRef(false);

  // ── 인증 부트스트랩 ──
  useEffect(() => {
    if (bootstrappedRef.current) return;
    bootstrappedRef.current = true;

    (async () => {
      try {
        if (new URLSearchParams(window.location.search).has('code')) {
          // redirect_uri(앱 루트) 복귀: code 교환 후 URL 정리
          const u = await authService.handleCallback();
          window.history.replaceState({}, '', '/');
          setUser(u);
        } else {
          // 새로고침: localStorage 의 User 복원. access_token 만료 시 refresh_token
          // 으로 갱신 (refresh 실패 → catch → 로그인 화면).
          let u = await authService.getUser();
          if (u?.expired) u = await authService.signinSilent();
          if (u && !u.expired) setUser(u);
        }
      } catch (e) {
        console.error('❌ 인증 부트스트랩 실패:', e);
      } finally {
        setAuthReady(true);
      }
    })();
  }, []);

  // ── WebSocket 연결 ──
  useEffect(() => {
    if (!user?.access_token) return;

    let socket: WebSocket | null = null;
    let pingTimer: ReturnType<typeof setInterval> | null = null;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
    let attempts = 0;
    let closedByCleanup = false;

    const startHeartbeat = (ws: WebSocket) => {
      // API GW idle timeout 10분 → 8분 주기 ping
      pingTimer = setInterval(() => {
        if (ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({ action: 'ping' }));
        }
      }, 8 * 60 * 1000);
    };

    const stopHeartbeat = () => {
      if (pingTimer) clearInterval(pingTimer);
      pingTimer = null;
    };

    const handleMessage = (data: WsMessage) => {
      if (data.type === 'pong') return;
      if (data.type === 'state') {
        // 매 수신마다 rooms 전체 교체. roomCatalog 메타데이터에 백엔드 occupancy 주입.
        // 프론트 id(room-a-1-lounge) → 백엔드 key(room_a_1_lounge) 변환.
        const next = roomCatalog.map((room) => ({
          ...room,
          isOccupied: data.rooms[room.id.replace(/-/g, '_')] ?? false,
        }));
        setRooms(next);

        if (data.timestamp) {
          const d = new Date(data.timestamp);
          setLastUpdated(`${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`);
        }
      }
    };

    const scheduleReconnect = () => {
      const delay = Math.min(1000 * 2 ** attempts, 30000); // 최대 30초
      attempts++;
      reconnectTimer = setTimeout(async () => {
        // 재연결 전 토큰 최신화 (만료 시 silent renew)
        let fresh = await authService.getUser();
        if (!fresh || fresh.expired) {
          try {
            fresh = await authService.signinSilent();
          } catch (e) {
            console.error('❌ silent renew 실패:', e);
          }
        }
        if (closedByCleanup) return;                  // BUG A: await 중 cleanup 레이스 → 중단
        if (fresh && !fresh.expired) {
          connect(fresh.access_token);
        } else {
          console.warn('🔒 토큰 갱신 실패 → 로그인 필요');
          setUser(null);                              // BUG F: 만료 무한루프 차단, LoginPage 폴백
        }
      }, delay);
    };

    const connect = (token: string) => {
      socket = new WebSocket(`${WS_BASE_URL}?token=${token}`);

      socket.onopen = () => {
        console.log('✅ WebSocket 연결 수립');
        attempts = 0; // 연결 성공 시 backoff 리셋
        startHeartbeat(socket!);
        socket!.send(JSON.stringify({ action: 'getState' })); // 초기 상태 요청
      };

      socket.onmessage = (event) => {
        try {
          handleMessage(JSON.parse(event.data) as WsMessage);
        } catch (error) {
          console.error('❌ WebSocket 메시지 파싱 오류:', error);
        }
      };

      socket.onerror = (error) => console.error('❌ WebSocket 통신 오류:', error);

      socket.onclose = () => {
        stopHeartbeat();
        if (!closedByCleanup) {
          console.log('🔌 WebSocket 종료. 재연결 예약...');
          scheduleReconnect();
        }
      };
    };

    connect(user.access_token);

    return () => {
      closedByCleanup = true;
      stopHeartbeat();
      if (reconnectTimer) clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, [user]);

  if (!authReady) {
    return (
      <div className="h-screen w-screen flex items-center justify-center bg-[#F7F9FB] text-[#1E293B] font-sans">
        Loading...
      </div>
    );
  }

  if (!user) {
    return <LoginPage onLogin={() => authService.login()} />;
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
          <IsometricBuilding rooms={rooms} isDarkMode={isDarkMode} />
        </div>
        <div className="hidden md:flex w-full h-full">
          <IntegratedBuilding rooms={rooms} isDarkMode={isDarkMode} />
        </div>
      </main>
    </div>
  );
}

export default App;
