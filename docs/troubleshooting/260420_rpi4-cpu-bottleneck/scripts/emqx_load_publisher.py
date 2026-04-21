#!/usr/bin/env python3
"""
emqx_load_publisher.py

MQTT 부하 테스트 - 각 센서가 지속 연결을 유지하며 주기 publish
실제 ESP32 동작 모사 (MQTT persistent connection)

사전 준비:
    pip install paho-mqtt

사용법:
    python emqx_load_publisher.py
    python emqx_load_publisher.py --interval 1 --duration 60
    python emqx_load_publisher.py --host 172.17.89.130 --port 11883 --sensors 9 --interval 5 --duration 300
"""

import argparse
import json
import random
import threading
import time
from datetime import datetime

try:
    import paho.mqtt.client as mqtt
except ImportError:
    print("ERROR: paho-mqtt not installed. Run: pip install paho-mqtt")
    exit(1)


class SensorWorker:
    def __init__(self, sensor_id, host, port, interval, duration):
        self.sensor_id = sensor_id
        self.host = host
        self.port = port
        self.interval = interval
        self.duration = duration
        self.topic = f"gikview/rooms/{sensor_id}/occupancy"
        self.client_id = f"loadtest-{sensor_id}"

        self.seq = 0
        self.success = 0
        self.failed = 0
        self.connected = False

        self.client = mqtt.Client(
            callback_api_version=mqtt.CallbackAPIVersion.VERSION2,
            client_id=self.client_id,
            clean_session=True,
        )
        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect

    def _on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            self.connected = True
        else:
            print(f"[{self.sensor_id}] CONNACK failed: {reason_code}")

    def _on_disconnect(self, client, userdata, flags, reason_code, properties):
        self.connected = False

    def run(self):
        # 연결 - 한 번만
        try:
            self.client.connect(self.host, self.port, keepalive=60)
            self.client.loop_start()
        except Exception as e:
            print(f"[{self.sensor_id}] connect error: {e}")
            return

        # 연결 확립 대기 (최대 5초)
        for _ in range(50):
            if self.connected:
                break
            time.sleep(0.1)

        if not self.connected:
            print(f"[{self.sensor_id}] connection timeout")
            return

        # 주기 publish - 같은 연결 유지
        end_time = time.time() + self.duration
        while time.time() < end_time:
            self.seq += 1
            payload = json.dumps({
                "sensor_id": self.sensor_id,
                "occupied": random.choice([True, False]),
                "timestamp": datetime.now().isoformat(timespec='milliseconds'),
                "seq": self.seq,
            })

            result = self.client.publish(self.topic, payload, qos=1)

            if result.rc == mqtt.MQTT_ERR_SUCCESS:
                self.success += 1
            else:
                self.failed += 1

            time.sleep(self.interval)

        # 정리
        self.client.loop_stop()
        self.client.disconnect()


def main():
    parser = argparse.ArgumentParser(description='MQTT load test - persistent connection')
    parser.add_argument('--host', default='172.17.89.130', help='Broker host')
    parser.add_argument('--port', type=int, default=11883, help='Broker port')
    parser.add_argument('--sensors', type=int, default=9, help='Sensor count')
    parser.add_argument('--interval', type=float, default=5.0, help='Publish interval (sec)')
    parser.add_argument('--duration', type=int, default=300, help='Test duration (sec)')
    args = parser.parse_args()

    print("=== MQTT Load Test (persistent connection) ===")
    print(f"Broker  : {args.host}:{args.port}")
    print(f"Sensors : {args.sensors}")
    print(f"Interval: {args.interval}s")
    print(f"Duration: {args.duration}s")
    print()

    # 연결 사전 검증
    test_client = mqtt.Client(callback_api_version=mqtt.CallbackAPIVersion.VERSION2)
    try:
        test_client.connect(args.host, args.port, keepalive=10)
        test_client.disconnect()
        print("Broker connection OK")
    except Exception as e:
        print(f"ERROR: broker connection failed: {e}")
        return

    print()

    # 센서 워커 생성 및 스레드 시작
    workers = []
    threads = []
    for i in range(1, args.sensors + 1):
        sensor_id = f"sensor-{i:02d}"
        w = SensorWorker(sensor_id, args.host, args.port, args.interval, args.duration)
        t = threading.Thread(target=w.run, name=sensor_id)
        workers.append(w)
        threads.append(t)
        t.start()
        print(f"Started: {sensor_id}")

    print()
    print(f"Running for {args.duration}s...")

    # 모든 스레드 완료 대기
    for t in threads:
        t.join()

    # 결과 요약
    print()
    print("=== Results ===")
    total_success = 0
    total_failed = 0
    for w in workers:
        status = "OK" if w.failed == 0 else "FAIL"
        print(f"  {w.sensor_id}: success={w.success} failed={w.failed} [{status}]")
        total_success += w.success
        total_failed += w.failed

    print()
    print(f"Total : success={total_success} failed={total_failed}")
    print("Done")


if __name__ == '__main__':
    main()