// web/src/components/RoomCard.tsx
import React from 'react';
import { Users, UserMinus } from 'lucide-react';
import type { Room } from '../types/room';

// 🚨 해결: 인터페이스 정의 추가
interface RoomCardProps {
  room: Room;
  onSelect?: (roomId: string) => void;
  isSelected?: boolean;
}

export const RoomCard: React.FC<RoomCardProps> = ({ room, onSelect, isSelected = false }) => {
  return (
    <div 
      // 🚨 해결: onSelect와 isSelected를 사용하여 '읽히지 않음' 에러 방지
      onClick={() => onSelect && onSelect(room.id)}
      className={`cursor-pointer p-5 rounded-2xl border transition-all duration-200 bg-white flex flex-col justify-between aspect-[4/3]
        ${isSelected ? 'ring-2 ring-blue-500 border-transparent shadow-lg' : 'border-slate-200 hover:border-slate-300 hover:shadow-md'}
      `}
    >
      <div>
        <div className="flex justify-between items-start mb-3">
          <span className="text-sm font-semibold text-slate-500">
            {room.building}동 {room.floor}층
          </span>
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
        <h3 className="text-xl font-bold text-slate-800 tracking-tight">{room.name}</h3>
      </div>
    </div>
  );
};