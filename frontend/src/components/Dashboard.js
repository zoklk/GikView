import React, { useState, useEffect } from 'react';
import mockData from '../mocks/roomData.json';

const Dashboard = () => {
  const [rooms, setRooms] = useState([]);

  useEffect(() => {
    // 7주차 API 연동 및 실시간 데이터 바인딩 테스트 전까지 Mock 데이터 사용
    setRooms(mockData);
  }, []);

  // 동별로 데이터 그룹화
  const groupedRooms = rooms.reduce((acc, room) => {
    if (!acc[room.building]) acc[room.building] = [];
    acc[room.building].push(room);
    return acc;
  }, {});

  return (
    <div style={{ padding: '20px', maxWidth: '1200px', margin: '0 auto', fontFamily: 'sans-serif' }}>
      <header style={{ borderBottom: '2px solid #eaeaea', paddingBottom: '15px', marginBottom: '30px' }}>
        <h1 style={{ margin: 0, color: '#333' }}>GikView - 기숙사 공용공간 재실 감지 대시보드</h1>
        <p style={{ margin: '10px 0 0 0', color: '#666' }}>mmWave 레이더 센서를 활용한 실시간 공간 모니터링</p>
      </header>

      {Object.entries(groupedRooms).map(([building, buildingRooms]) => (
        <section key={building} style={{ marginBottom: '40px' }}>
          <h2 style={{ borderLeft: '4px solid #0056b3', paddingLeft: '10px', color: '#0056b3' }}>
            {building}
          </h2>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(280px, 1fr))', gap: '20px' }}>
            {buildingRooms.map((room) => (
              <div 
                key={room.roomId}
                style={{
                  padding: '20px',
                  borderRadius: '12px',
                  border: `1px solid ${room.isOccupied ? '#f5c6cb' : '#c3e6cb'}`,
                  backgroundColor: room.isOccupied ? '#fff3f4' : '#f4fff5',
                  boxShadow: '0 4px 6px rgba(0,0,0,0.05)',
                }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                  <div>
                    <span style={{ fontSize: '0.85rem', color: '#666', fontWeight: 'bold' }}>{room.floor}</span>
                    <h3 style={{ margin: '5px 0 10px 0', fontSize: '1.2rem', color: '#333' }}>{room.roomName}</h3>
                  </div>
                  <span style={{
                    padding: '5px 10px',
                    borderRadius: '20px',
                    fontSize: '0.85rem',
                    fontWeight: 'bold',
                    backgroundColor: room.isOccupied ? '#dc3545' : '#28a745',
                    color: 'white'
                  }}>
                    {room.isOccupied ? '사용 중' : '비어있음'}
                  </span>
                </div>
                {room.note && (
                  <p style={{ margin: '15px 0 0 0', fontSize: '0.8rem', color: '#856404', backgroundColor: '#fff3cd', padding: '8px', borderRadius: '4px' }}>
                    * {room.note}
                  </p>
                )}
              </div>
            ))}
          </div>
        </section>
      ))}
    </div>
  );
};

export default Dashboard;