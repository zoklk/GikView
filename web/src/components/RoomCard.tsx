import React from 'react';
import type { RoomStatus } from '../types/room';
import { Users, UserMinus, Clock } from 'lucide-react';

interface RoomCardProps {
  room: RoomStatus;
  onSelect: (roomId: string) => void;
  isSelected: boolean;
}

export const RoomCard: React.FC<RoomCardProps> = ({ room, onSelect, isSelected }) => {
  const { roomId, roomName, isOccupied, updatedAt } = room;

  return (
    <div 
      onClick={() => onSelect(roomId)}
      className={`cursor-pointer p-5 rounded-2xl border transition-all duration-200 bg-white
        ${isSelected ? 'ring-2 ring-blue-500 border-transparent shadow-lg' : 'border-slate-200 hover:border-slate-300 hover:shadow-md'}
      `}
    >
      <div className="flex justify-between items-start mb-4">
        <h3 className="text-lg font-bold text-slate-800 tracking-tight">{roomName}</h3>
        <span className={`px-3 py-1 rounded-full text-xs font-semibold flex items-center gap-1
          ${isOccupied ? 'bg-red-50 text-red-600 border border-red-200' : 'bg-green-50 text-green-600 border border-green-200'}
        `}>
          {isOccupied ? (
            <>
              <Users size={14} /> 재실 중
            </>
          ) : (
            <>
              <UserMinus size={14} /> 비어있음
            </>
          )}
        </span>
      </div>

      <div className="flex items-center gap-1.5 text-xs text-slate-400 mt-2">
        <Clock size={14} />
        <span>최근 갱신: {new Date(updatedAt).toLocaleTimeString('ko-KR')}</span>
      </div>
    </div>
  );
};