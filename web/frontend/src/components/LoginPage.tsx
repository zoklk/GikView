import React from 'react';

interface LoginPageProps {
  onLogin: () => void;
}

export const LoginPage: React.FC<LoginPageProps> = ({ onLogin }) => {
  return (
    <div className="min-h-screen w-full bg-[#F7F9FB] text-[#1E293B] font-sans flex flex-col items-center overflow-x-hidden">
      <header className="w-full max-w-5xl px-6 py-8 flex justify-between items-center shrink-0">
        <h1 className="text-3xl md:text-4xl font-black tracking-tighter text-[#1F7A8C]">
          GikView
        </h1>
        <button 
          onClick={onLogin}
          className="text-xl md:text-2xl font-bold hover:opacity-60 transition-opacity cursor-pointer p-2"
        >
          로그인
        </button>
      </header>

      <main className="w-full max-w-5xl px-6 flex flex-col gap-24 pb-32 pt-10">
        <div className="w-full aspect-video md:aspect-[21/9] bg-[#FFFFFF] border-2 border-[#D7DEE8] rounded-3xl shadow-sm overflow-hidden relative">
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
        <div className="w-full aspect-video md:aspect-[21/9] bg-[#FFFFFF] border-2 border-[#D7DEE8] rounded-3xl flex items-center justify-center shadow-sm overflow-hidden relative p-4 md:p-8">
          <img 
            src="/스크린샷 2026-06-03 130917.png" 
            alt="기숙사 공용공간 구조도" 
            className="w-full h-full object-contain" 
          />
        </div>

        <div className="text-center px-4">
          <p className="text-lg md:text-2xl font-medium leading-relaxed opacity-80 break-keep">
            공용공간의 재실 감지를 일상에 담아보았습니다.<br className="hidden md:block" />
            같이 사용하는 공용공간 편하게 이용하세요.
          </p>
        </div>

        <div className="flex justify-center pt-8">
          <button
            onClick={onLogin}
            className="bg-[#1F7A8C] text-[#FFFFFF] py-4 px-12 text-xl font-bold rounded-full shadow-lg hover:opacity-90 hover:-translate-y-1 transition-all duration-300"
          >
            서비스 시작하기
          </button>
        </div>

      </main>
    </div>
  );
};