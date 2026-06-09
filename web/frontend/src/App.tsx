import { useState, useEffect, useRef, useMemo } from 'react';
import type { User } from 'oidc-client-ts';
import { IntegratedBuilding } from './components/IntegratedBuilding';
import { IsometricBuilding } from './components/IsometricBuilding';
import { LoginPage } from './components/LoginPage';
import { WS_BASE_URL } from './services/api';
import { authService } from './services/auth';
import { roomCatalog } from './data/roomCatalog'; // 방 메타데이터(이름/층/동) 베이스
import { STATUS } from './theme';
import type { Room } from './types/room';
import type { WsMessage } from './types/ws';

const pad = (n: number) => n.toString().padStart(2, '0');

// 다크모드 초기값: 저장값 우선, 없으면 시스템 설정 폴백
const getInitialDark = () => {
  const saved = localStorage.getItem('theme');
  if (saved) return saved === 'dark';
  return window.matchMedia('(prefers-color-scheme: dark)').matches;
};

function App() {
  const [user, setUser] = useState<User | null>(null);
  const [authReady, setAuthReady] = useState(false);
  const [isDarkMode, setIsDarkMode] = useState(getInitialDark);
  const [rooms, setRooms] = useState<Room[]>(roomCatalog);
  const [lastUpdated, setLastUpdated] = useState<string>('');
  // 활성 빌딩 단일 마운트용. display 토글(md:hidden) 대신 조건부 렌더 →
  // 보이는 상태에서만 SVG fill 주입(숨김 중 칠하면 Chrome repaint 누락 버그).
  const [isDesktop, setIsDesktop] = useState(() => window.matchMedia('(min-width: 768px)').matches);

  // 다크모드 영속화
  useEffect(() => {
    localStorage.setItem('theme', isDarkMode ? 'dark' : 'light');
  }, [isDarkMode]);

  // md(768px) 경계 추적 → 활성 빌딩 전환
  useEffect(() => {
    const mq = window.matchMedia('(min-width: 768px)');
    const onChange = (e: MediaQueryListEvent) => setIsDesktop(e.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);

  // 재실 요약: 한눈에 빈 방/사용 중 파악
  const counts = useMemo(() => {
    let free = 0, occupied = 0, unknown = 0;
    for (const r of rooms) {
      if (r.isOccupied === null) unknown++;
      else if (r.isOccupied) occupied++;
      else free++;
    }
    return { free, occupied, unknown, total: rooms.length };
  }, [rooms]);

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
        if (closedByCleanup) return;                  // await 중 언마운트 레이스 가드
        if (fresh && !fresh.expired) {
          connect(fresh.access_token);
        } else {
          console.warn('🔒 토큰 갱신 실패 → 로그인 필요');
          setUser(null);                              // 만료 무한 재연결 차단 → LoginPage 폴백
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
      <div className={`app-surface h-dvh w-dvw flex items-center justify-center ${isDarkMode ? 'dark' : ''}`}>
        <div className="flex items-center gap-3 text-[#1E293B] dark:text-slate-100">
          <span className="h-5 w-5 rounded-full border-2 border-[#1F7A8C]/30 border-t-[#1F7A8C] animate-spin" />
          <span className="text-sm font-medium tracking-wide opacity-70">불러오는 중…</span>
        </div>
      </div>
    );
  }

  if (!user) {
    return <LoginPage onLogin={() => authService.login()} />;
  }

  return (
    <div className={`app-surface h-dvh w-dvw overflow-hidden flex flex-col select-none ${isDarkMode ? 'dark' : ''}`}>
      <header className="glass z-20 shrink-0 shadow-[0_4px_24px_-12px_rgba(15,23,42,0.25)]">
        <div className="flex justify-between items-center px-4 md:px-7 py-3 md:py-4">
          <div className="flex items-center gap-2.5">
            <button
              onClick={() => setIsDarkMode(!isDarkMode)}
              aria-label="테마 전환"
              className="grid place-items-center h-9 w-9 rounded-xl glass text-[#1F7A8C] dark:text-[#2EBFA5] shadow-sm hover:scale-105 active:scale-95 transition-transform"
            >
              <ThemeIcon dark={isDarkMode} />
            </button>
            <div className="flex items-center gap-1.5 text-[11px] md:text-xs font-semibold text-slate-500 dark:text-slate-400">
              <span className="relative flex h-2 w-2">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-[#2EBFA5] opacity-75" />
                <span className="relative inline-flex rounded-full h-2 w-2 bg-[#2EBFA5]" />
              </span>
              {lastUpdated || '연결 중'}
            </div>
          </div>

          <div className="flex flex-col items-end">
            <h1 className="text-3xl md:text-4xl font-black italic tracking-tighter uppercase leading-none text-[#1E293B] dark:text-[#E6F4F3]">
              Gik<span className="text-[#1F7A8C] dark:text-[#2EBFA5]">View</span>
            </h1>
            <span className="mt-1.5 h-1 w-16 md:w-20 rounded-full bg-gradient-to-r from-[#1F7A8C] to-[#2EBFA5]" />
          </div>
        </div>

        {/* 재실 요약 범례 — 색 의존 줄이고 텍스트+카운트로 직관 강화 */}
        <div className="flex items-center gap-2 px-4 md:px-7 pb-2.5 -mt-0.5 overflow-x-auto">
          <LegendChip color={STATUS.free} label="비어있음" count={counts.free} />
          <LegendChip color={STATUS.occupied} label="사용 중" count={counts.occupied} />
          {counts.unknown > 0 && (
            <LegendChip color={STATUS.unknown} label="확인 중" count={counts.unknown} />
          )}
        </div>
      </header>

      <main className="flex-1 w-full h-full relative overflow-hidden">
        {isDesktop ? (
          <IntegratedBuilding rooms={rooms} isDarkMode={isDarkMode} />
        ) : (
          <IsometricBuilding rooms={rooms} isDarkMode={isDarkMode} />
        )}
      </main>
    </div>
  );
}

// Sun/Moon 인라인 아이콘 (lucide path). 아이콘 한두 개 위해 lucide-react 배럴
// 전체(1500+ 모듈) 끌어오면 prod 번들러 부하 → 인라인으로 대체.
function ThemeIcon({ dark }: { dark: boolean }) {
  return (
    <svg
      width={17} height={17} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round"
    >
      {dark ? (
        <path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9Z" />
      ) : (
        <>
          <circle cx="12" cy="12" r="4" />
          <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M6.34 17.66l-1.41 1.41M19.07 4.93l-1.41 1.41" />
        </>
      )}
    </svg>
  );
}

function LegendChip({ color, label, count }: { color: string; label: string; count: number }) {
  return (
    <span className="inline-flex items-center gap-1.5 shrink-0 rounded-full glass px-2.5 py-1 text-[11px] md:text-xs font-semibold text-slate-600 dark:text-slate-300 shadow-sm">
      <span className="h-2 w-2 rounded-full" style={{ backgroundColor: color }} />
      {label}
      <span className="tabular-nums font-bold text-[#1E293B] dark:text-white">{count}</span>
    </span>
  );
}

export default App;
