import React from 'react';
import type { OccupancyHistory } from '../types/room';
import { LogIn, LogOut, Info } from 'lucide-react';

interface HistoryPanelProps {
  roomName: string;
  histories: OccupancyHistory[];
  isLoading: boolean;
}

export const HistoryPanel: React.FC<HistoryPanelProps> = ({ roomName, histories, isLoading }) => {
  return (
    <div className="bg-white rounded-2xl border border-slate-200 p-6 shadow-sm">
      <h3 className="text-xl font-bold text-slate-800 mb-4">{roomName} 이용 이력</h3>
      
      {isLoading ? (
        <div className="text-slate-400 text-sm py-8 text-center">이력을 불러오는 중입니다...</div>
      ) : histories.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-8 text-slate-400 gap-2">
          <Info size={24} className="text-slate-300" />
          <p className="text-sm">최근 7일간 상태 변경 이력이 없습니다.</p>
        </div>
      ) : (
        <div className="relative border-l border-slate-200 ml-3 pl-5 space-y-6">
          {histories.map((history) => (
            <div key={history.id} className="relative">
              {/* 타임라인 마커 기호 */}
              <span className={`absolute -left-[29px] top-0.5 rounded-full p-1 bg-white border-2
                ${history.status === 'ENTER' ? 'border-red-500 text-red-500' : 'border-green-500 text-green-500'}
              `}>
                {history.status === 'ENTER' ? <LogIn size={12} /> : <LogOut size={12} />}
              </span>
              
              <div>
                <span className="font-semibold text-slate-700 text-sm">
                  {history.status === 'ENTER' ? '이용 시작 (재실)' : '이용 종료 (공실)'}
                </span>
                <p className="text-xs text-slate-400 mt-0.5">
                  {new Date(history.timestamp).toLocaleString('ko-KR')}
                </p>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};