import React from 'react';

interface LoginPageProps {
  onLogin: () => void;
}

export const LoginPage: React.FC<LoginPageProps> = ({ onLogin }) => {
  return (
    <div className="app-surface min-h-screen w-full flex flex-col items-center overflow-x-hidden">
      <header className="sticky top-0 z-20 w-full flex justify-center">
        <div className="w-full max-w-5xl mx-4 mt-4 glass rounded-2xl shadow-[0_4px_24px_-12px_rgba(15,23,42,0.25)] px-5 md:px-7 py-3.5 flex justify-between items-center">
          <h1 className="text-2xl md:text-3xl font-black italic tracking-tighter uppercase">
            Gik<span className="text-[#1F7A8C]">View</span>
          </h1>
          <button
            onClick={onLogin}
            className="rounded-full px-5 py-2 text-sm md:text-base font-bold text-[#1F7A8C] hover:bg-[#1F7A8C]/8 active:scale-95 transition-all cursor-pointer"
          >
            로그인
          </button>
        </div>
      </header>

      <main className="w-full max-w-5xl px-6 flex flex-col gap-20 md:gap-24 pb-32 pt-12 md:pt-16">
        {/* 히어로 */}
        <div className="w-full aspect-video md:aspect-[21/9] glass rounded-3xl shadow-[0_24px_60px_-28px_rgba(15,23,42,0.4)] overflow-hidden relative">
          <img
            src="/unnamed.webp"
            alt="GIST 기숙사 전경"
            className="w-full h-full object-cover hover:scale-105 transition-transform duration-700 ease-in-out"
          />
        </div>

        <div className="text-center px-4">
          <h2 className="text-2xl md:text-4xl font-bold leading-snug break-keep">
            우리가 생활하는 기숙사 그리고 같이<br className="hidden md:block" /> 사용하는 공용공간
          </h2>
        </div>

        {/* 구조도: 비율 깨짐 방지 위해 object-contain */}
        <div className="w-full aspect-video md:aspect-[21/9] glass rounded-3xl flex items-center justify-center shadow-[0_24px_60px_-28px_rgba(15,23,42,0.4)] overflow-hidden relative p-4 md:p-8">
          <img
            src="/스크린샷 2026-06-03 130917.png"
            alt="기숙사 공용공간 구조도"
            className="w-full h-full object-contain"
          />
        </div>

        <div className="text-center px-4">
          <p className="text-lg md:text-2xl font-medium leading-relaxed opacity-70 break-keep">
            공용공간의 재실 감지를 일상에 담아보았습니다.<br className="hidden md:block" />
            같이 사용하는 공용공간 편하게 이용하세요.
          </p>
        </div>

        <div className="flex justify-center pt-4">
          <button
            onClick={onLogin}
            className="bg-gradient-to-r from-[#1F7A8C] to-[#2EBFA5] text-white py-4 px-12 text-xl font-bold rounded-full shadow-[0_16px_40px_-12px_rgba(31,122,140,0.6)] hover:-translate-y-1 hover:shadow-[0_22px_50px_-12px_rgba(31,122,140,0.7)] active:translate-y-0 transition-all duration-300 cursor-pointer"
          >
            서비스 시작하기
          </button>
        </div>
      </main>
    </div>
  );
};
