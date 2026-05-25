// src/components/RoomCard.tsx
import React from 'react';
import type { Room } from '../types/room'; // 새로 만든 타입 가져오기
import { Users, UserMinus } from 'lucide-react';

interface RoomCardProps {
  room: Room;
  onSelect?: (roomId: string) => void;
  isSelected?: boolean;
}

export const RoomCard: React.FC<RoomCardProps> = ({ room, onSelect, isSelected = false }) => {
  return (
    <div 
      onClick={() => onSelect && onSelect(room.id)}
      // aspect-[4/3]을 추가하여 웹/앱 모두에서 카드가 찌그러지지 않고 4:3 황금비율 유지
      className={`cursor-pointer p-5 rounded-2xl border transition-all duration-200 bg-white flex flex-col justify-between aspect-[4/3]
        ${isSelected ? 'ring-2 ring-blue-500 border-transparent shadow-lg' : 'border-slate-200 hover:border-slate-300 hover:shadow-md'}
      `}
    >
      <div>
        <div className="flex justify-between items-start mb-3">
          {/* 건물과 층수 표시 */}
          <span className="text-sm font-semibold text-slate-500">
            {room.building}동 {room.floor}층
          </span>
          {/* 제실 여부 배지 */}
          <span className={`px-2 py-1 rounded-full text-xs font-bold flex items-center gap-1
            ${room.isOccupied ? 'bg-red-50 text-red-600 border border-red-200' : 'bg-green-50 text-green-600 border border-green-200'}
          `}>
            {room.isOccupied ? (
              <><Users size={14} /> 사용 중</>
            ) : (
              <><UserMinus size={14} /> 비어있음</>
            )}
          </span>
        </div>
        
        {/* 방 이름 */}
        <h3 className="text-xl font-bold text-slate-800 tracking-tight">{room.name}</h3>

        {/* 예약 정보 등 추가 설명이 있을 경우에만 렌더링 */}
        {room.description && (
          <p className="text-xs text-slate-400 mt-2 line-clamp-2">
            {room.description}
          </p>
        )}
      </div>
    </div>
  );
};