// src/App.tsx
import { useState } from 'react';
import { RoomCard } from './components/RoomCard';
import { mockRooms } from './mock/roomMock';

function App() {
  const [selectedRoomId, setSelectedRoomId] = useState<string | null>(null);

  return (
    // 모바일 웹뷰 대응: overflow-x-hidden으로 가로 스크롤 원천 차단
    <div className="min-h-screen bg-slate-50 overflow-x-hidden p-4 md:p-8">
      <header className="mb-6 md:mb-8">
        <h1 className="text-2xl md:text-3xl font-bold text-slate-800 tracking-tight">
          GIST 제실 감지 시스템
        </h1>
        <p className="text-slate-500 mt-1 text-sm md:text-base">
          실시간 교내 공간 사용 현황을 확인하세요.
        </p>
      </header>

      {/* 핵심 반응형 그리드 시스템 */}
      {/* 모바일(기본): 1열 (grid-cols-1)
        태블릿(sm): 2열 (sm:grid-cols-2)
        노트북(lg): 3열 (lg:grid-cols-3)
        대형모니터(xl): 4열 (xl:grid-cols-4)
      */}
      <main className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4 md:gap-6">
        {mockRooms.map((room) => (
          <RoomCard
            key={room.id}
            room={room}
            isSelected={selectedRoomId === room.id}
            onSelect={setSelectedRoomId}
          />
        ))}
      </main>
    </div>
  );
}

export default App;