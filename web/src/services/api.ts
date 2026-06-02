import axios from 'axios';
import { authService } from './auth';
import type { RoomStatus, OccupancyHistory } from '../types/room';

const API_BASE_URL = 'https://your-api-gateway-url.amazonaws.com/prod';

const apiClient = axios.create({
  baseURL: API_BASE_URL,
});

apiClient.interceptors.request.use(async (config) => {
  const user = await authService.getUser();
  if (user && user.access_token) {
    config.headers.Authorization = `Bearer ${user.access_token}`;
  }
  return config;
}, (error) => Promise.reject(error));

// 기숙사 공용공간 9개 가짜 데이터 생성
export const fetchRoomStatuses = async (): Promise<RoomStatus[]> => {
  return Array.from({ length: 9 }, (_, i) => ({
    roomId: `ROOM_0${i + 1}`,
    roomName: `기숙사 공용공간 ${i + 1}`,
    isOccupied: i % 3 === 0, // 일부 방만 재실 상태로 표시
    updatedAt: new Date().toISOString(),
  }));
};

// 특정 방의 가짜 이력 데이터 생성
export const fetchRoomHistory = async (roomId: string): Promise<OccupancyHistory[]> => {
  return [
    { id: '1', roomId, status: 'ENTER', timestamp: new Date(Date.now() - 1000 * 60 * 10).toISOString() },
    { id: '2', roomId, status: 'LEAVE', timestamp: new Date(Date.now() - 1000 * 60 * 50).toISOString() }
  ];
};