import { useEffect, useState } from 'react';
import type { RoomStatus, OccupancyHistory } from './types/room';
import { fetchRoomStatuses, fetchRoomHistory } from './services/api';
import { authService } from './services/auth';
import { RoomCard } from './components/RoomCard';
import { HistoryPanel } from './components/HistoryPanel';
import { LayoutDashboard, RefreshCw, LogOut } from 'lucide-react';

function App() {
  const [isAuthenticated, setIsAuthenticated] = useState<boolean>(false);
  const [rooms, setRooms] = useState<RoomStatus[]>([]);
  const [selectedRoomId, setSelectedRoomId] = useState<string | null>("ROOM_01");
  const [histories, setHistories] = useState<OccupancyHistory[]>([]);
  const [isHistoryLoading, setIsHistoryLoading] = useState<boolean>(false);
  const [isRefreshing, setIsRefreshing] = useState<boolean>(false);

  // 1. 보안 인증 관리 (GIST IdP JWT 토큰 체크)
  useEffect(() => {
    // 기존의 authService.getUser().then(...) 로직을 지우고 아래 한 줄로 대체합니다.
    // 백엔드 연동 전까지 UI 개발을 위해 강제로 로그인 완료 상태로 설정
    setIsAuthenticated(true);
  }, []);

  // 2. 룸 현황 정보 로드 함수
  const loadDashboardData = async () => {
    if (!isAuthenticated) return;
    setIsRefreshing(true);
    try {
      const data = await fetchRoomStatuses();
      setRooms(data);
    } catch (error) {
      console.error("데이터 로드 실패:", error);
    } finally {
      setIsRefreshing(false);
    }
  };

  // 3. 선택된 룸의 이력 로드 함수
  const loadHistoryData = async (roomId: string) => {
    if (!isAuthenticated) return;
    setIsHistoryLoading(true);
    try {
      const data = await fetchRoomHistory(roomId);
      setHistories(data);
    } catch (error) {
      console.error("이력 로드 실패:", error);
    } finally {
      setIsHistoryLoading(false);
    }
  };

  // 인증이 완료된 후 데이터 초기 로드 및 60초 주기적 폴링 세팅
  useEffect(() => {
    if (isAuthenticated) {
      loadDashboardData();
      const interval = setInterval(loadDashboardData, 60000);
      return () => clearInterval(interval);
    }
  }, [isAuthenticated]);

  // 카드 선택 변경 시 이력 데이터 자동 갱신
  useEffect(() => {
    if (isAuthenticated && selectedRoomId) {
      loadHistoryData(selectedRoomId);
    }
  }, [selectedRoomId, isAuthenticated]);

  const selectedRoom = rooms.find(r => r.roomId === selectedRoomId);

  // 인증 확인 중일 때 보일 화면
  if (!isAuthenticated) {
    return (
      <div className="min-h-screen flex items-center justify-center bg-slate-50">
        <div className="text-slate-500 text-sm font-medium animate-pulse">
          GIST 로그인 확인 중...
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-slate-50">
      {/* 글로벌 네비게이션 바 */}
      <header className="bg-white border-b border-slate-200 sticky top-0 z-50">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
          <div className="flex items-center gap-2">
            <LayoutDashboard className="text-blue-600" size={24} />
            <span className="text-xl font-black text-slate-800 tracking-tight">GikView</span>
            <span className="text-xs bg-slate-100 text-slate-500 font-medium px-2 py-0.5 rounded-md">기숙사 공용공간 재실 감지</span>
          </div>
          <div className="flex items-center gap-3">
            <button 
              onClick={loadDashboardData}
              disabled={isRefreshing}
              className="flex items-center gap-1.5 text-xs font-semibold px-3 py-2 border border-slate-200 rounded-xl bg-white hover:bg-slate-50 text-slate-600 transition-colors"
            >
              <RefreshCw size={14} className={isRefreshing ? 'animate-spin' : ''} />
              새로고침
            </button>
            <button 
              onClick={() => authService.logout()}
              className="flex items-center gap-1.5 text-xs font-semibold px-3 py-2 rounded-xl bg-slate-100 hover:bg-slate-200 text-slate-600 transition-colors"
            >
              <LogOut size={14} />
              로그아웃
            </button>
          </div>
        </div>
      </header>

      {/* 메인 레이아웃 뷰 포트 */}
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
          
          {/* 좌측/중앙: 실시간 현황판 그리드 (9개 룸 배치 영역) */}
          <div className="lg:col-span-2 space-y-4">
            <div className="flex justify-between items-center mb-2">
              <h2 className="text-lg font-bold text-slate-700">실시간 공간 현황</h2>
              <p className="text-xs text-slate-400">60초 간격으로 자동 동기화 중</p>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
              {rooms.map((room) => (
                <RoomCard 
                  key={room.roomId}
                  room={room}
                  onSelect={setSelectedRoomId}
                  isSelected={selectedRoomId === room.roomId}
                />
              ))}
            </div>
          </div>

          {/* 우측: 사이드 바인딩 이력 패널 */}
          <div className="lg:col-span-1">
            <div className="sticky top-24">
              {selectedRoom ? (
                <HistoryPanel 
                  roomName={selectedRoom.roomName}
                  histories={histories}
                  isLoading={isHistoryLoading}
                />
              ) : (
                <div className="bg-white border border-slate-200 p-6 rounded-2xl text-center text-slate-400 text-sm">
                  공간을 선택하시면 상세 이용 이력이 이곳에 표시됩니다.
                </div>
              )}
            </div>
          </div>

        </div>
      </main>
    </div>
  );
}

export default App;