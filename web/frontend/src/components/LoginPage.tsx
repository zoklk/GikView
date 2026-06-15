import React from 'react';
import { IntegratedBuilding } from './IntegratedBuilding';
import { Backdrop } from './Backdrop';
import { ThemeIcon } from './ThemeIcon';
import { roomCatalog } from '../data/roomCatalog';
import { STATUS } from '../theme';
import type { Room } from '../types/room';

interface LoginPageProps {
  onLogin: () => void;
  isDarkMode: boolean;
  onToggleDark: () => void;
}

// 랜딩 맵 프리뷰용 목업 점유 — 실제 IntegratedBuilding 에 주입해 "보게 될 화면"을
// 로그인 전 예시로 노출. 로그인 후엔 WS state 가 실제 점유로 덮어씀.
const OCCUPIED = new Set([
  'room-a-1-lounge',
  'room-a-2-lounge',
  'room-a-3-lounge1',
  'room-b-2-meeting',
  'room-b-3-meeting',
]);
const previewRooms: Room[] = roomCatalog.map((r) => ({
  ...r,
  isOccupied: OCCUPIED.has(r.id),
}));

export const LoginPage: React.FC<LoginPageProps> = ({ onLogin, isDarkMode, onToggleDark }) => {
  return (
    <div
      className={`app-surface relative min-h-dvh w-full flex flex-col items-center overflow-x-hidden ${
        isDarkMode ? 'dark' : ''
      }`}
    >
      <Backdrop />

      {/* 헤더 */}
      <header className="sticky top-0 z-20 w-full flex justify-center">
        <div className="w-full max-w-5xl mx-4 mt-4 glass rounded-2xl shadow-[0_4px_24px_-12px_rgba(15,23,42,0.25)] px-5 md:px-7 py-3.5 flex justify-between items-center">
          <h1 className="text-2xl md:text-3xl font-black italic tracking-tighter uppercase text-[#1E293B] dark:text-[#E6F4F3]">
            Gik<span className="text-[#1F7A8C] dark:text-[#2EBFA5]">View</span>
          </h1>
          <div className="flex items-center gap-1.5">
            <button
              onClick={onToggleDark}
              aria-label="테마 전환"
              className="grid place-items-center h-9 w-9 rounded-xl glass text-[#1F7A8C] dark:text-[#2EBFA5] shadow-sm hover:scale-105 active:scale-95 transition-transform"
            >
              <ThemeIcon dark={isDarkMode} />
            </button>
            <button
              onClick={onLogin}
              className="rounded-full px-5 py-2 text-sm md:text-base font-bold text-[#1F7A8C] dark:text-[#2EBFA5] hover:bg-[#1F7A8C]/8 active:scale-95 transition-all cursor-pointer"
            >
              로그인
            </button>
          </div>
        </div>
      </header>

      {/* ── 단일 스테이지: 타이트 카피 + 제품(맵)이 주인공 ── */}
      <main className="relative z-10 w-full max-w-5xl px-6 pt-14 md:pt-20 pb-16 flex flex-col items-center">
        <h2 className="text-center text-4xl md:text-6xl font-black tracking-tight leading-[1.1] break-keep text-[#1E293B] dark:text-[#E6F4F3]">
          공용공간, 가기 전에
          <br />
          <span className="text-[#1F7A8C] dark:text-[#2EBFA5]">비었는지</span> 확인하세요
        </h2>
        <p className="mt-5 text-center text-base md:text-xl font-medium opacity-60 break-keep max-w-xl">
          같이 쓰는 라운지·휴게실이 지금 비었는지 한눈에.
        </p>
        <div className="mt-8">
          <CtaButton onClick={onLogin} label="빈 공간 보러가기" />
        </div>

        {/* 제품 앵커: 전폭 라이브 맵. 범례·프라이버시·캡션을 한 컴포지션으로 통합. */}
        <div className="mt-12 md:mt-16 w-full glass rounded-3xl shadow-[0_30px_80px_-32px_rgba(15,23,42,0.5)] overflow-hidden">
          {/* 불투명 표면 — 반투명 glass 너머로 배경(그리드·글로우)이 비쳐 벡터가
              뿌예지는 것 차단. 벡터가 깨끗한 면 위에 선명히 렌더. */}
          <div className="h-[clamp(260px,52vh,520px)] bg-[var(--surface-from)]">
            <IntegratedBuilding rooms={previewRooms} isDarkMode={isDarkMode} />
          </div>

          {/* 범례 + 프라이버시 칩(외톨이 섹션 대신 여기 흡수) */}
          <div className="flex flex-wrap items-center justify-center gap-2.5 px-4 pt-1">
            <LegendChip color={STATUS.free} label="비어있음" />
            <LegendChip color={STATUS.occupied} label="사용 중" />
            <span className="hidden sm:inline-block h-3.5 w-px bg-current opacity-15" />
            <span className="inline-flex items-center gap-1.5 rounded-full glass px-2.5 py-1 text-[11px] md:text-xs font-semibold text-slate-600 dark:text-slate-300 shadow-sm">
              <span className="text-[#1F7A8C] dark:text-[#2EBFA5]">
                <CameraOffIcon size={14} />
              </span>
              카메라 없이 빈자리만 감지
            </span>
          </div>

          <p className="text-center text-[11px] md:text-xs font-medium opacity-45 pt-2 pb-4">
            로그인하면 보이는 실시간 현황 · 지금은 예시 화면이에요
          </p>
        </div>
      </main>

      {/* 푸터 */}
      <footer className="relative z-10 w-full max-w-5xl px-6 py-8 text-center text-xs md:text-sm font-medium opacity-40">
        GikView · GIST 생활관 공용공간 재실 현황
      </footer>
    </div>
  );
};

function CtaButton({ onClick, label }: { onClick: () => void; label: string }) {
  return (
    <button
      onClick={onClick}
      className="bg-gradient-to-r from-[#1F7A8C] to-[#2EBFA5] text-white py-3.5 md:py-4 px-10 md:px-12 text-lg md:text-xl font-bold rounded-full shadow-[0_16px_40px_-12px_rgba(31,122,140,0.6)] hover:-translate-y-1 hover:shadow-[0_22px_50px_-12px_rgba(31,122,140,0.7)] active:translate-y-0 transition-all duration-300 cursor-pointer"
    >
      {label}
    </button>
  );
}

// 카메라 금지 (lucide camera-off). 프라이버시 안심용 인라인 아이콘.
function CameraOffIcon({ size = 26 }: { size?: number }) {
  return (
    <svg
      width={size} height={size} viewBox="0 0 24 24" fill="none"
      stroke="currentColor" strokeWidth={2} strokeLinecap="round" strokeLinejoin="round"
    >
      <path d="M2 2l20 20" />
      <path d="M7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h13" />
      <path d="M9.5 4h5L17 7h3a2 2 0 0 1 2 2v7.5" />
      <path d="M14.121 15.121A3 3 0 1 1 9.88 10.88" />
    </svg>
  );
}

function LegendChip({ color, label }: { color: string; label: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 rounded-full glass px-2.5 py-1 text-[11px] md:text-xs font-semibold text-slate-600 dark:text-slate-300 shadow-sm">
      <span className="h-2 w-2 rounded-full" style={{ backgroundColor: color }} />
      {label}
    </span>
  );
}
