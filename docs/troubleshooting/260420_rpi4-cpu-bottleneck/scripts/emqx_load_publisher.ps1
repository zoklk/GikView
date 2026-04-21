# emqx_load_publisher.ps1
# MQTT 부하 테스트 - 9개 센서를 병렬로 publish

param(
    [string]$BrokerHost = "172.17.89.130",
    [int]$BrokerPort = 11883,
    [int]$SensorCount = 9,
    [int]$IntervalSec = 5,
    [int]$DurationSec = 300
)

# mosquitto_pub 전체 경로 - Job 내부에서 사용
$MosquittoPub = "C:\Program Files\mosquitto\mosquitto_pub.exe"

if (-not (Test-Path $MosquittoPub)) {
    Write-Error "mosquitto_pub not found at: $MosquittoPub"
    exit 1
}

Write-Host "Using: $MosquittoPub"

# 연결 사전 검증
Write-Host "Testing broker connection..."
$testResult = & $MosquittoPub -h $BrokerHost -p $BrokerPort -t "loadtest/ping" -m "test" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Broker connection test failed: $testResult"
    exit 1
}
Write-Host "Broker connection OK"

$EndTime = (Get-Date).AddSeconds($DurationSec)

Write-Host ""
Write-Host "=== MQTT Load Test ==="
Write-Host "Broker  : ${BrokerHost}:${BrokerPort}"
Write-Host "Sensors : $SensorCount"
Write-Host "Interval: ${IntervalSec}s"
Write-Host "Duration: ${DurationSec}s"
Write-Host ""

# 각 센서를 백그라운드 job으로 실행
$Jobs = @()
for ($i = 1; $i -le $SensorCount; $i++) {
    $SensorId = "sensor-{0:D2}" -f $i
    $Topic = "gikview/rooms/$SensorId/occupancy"
    $ClientId = "loadtest-$SensorId"

    $Job = Start-Job -ScriptBlock {
        param($mosqBin, $h, $p, $topic, $clientId, $interval, $endTime, $sensorId)

        $count = 0
        $failCount = 0

        while ((Get-Date) -lt $endTime) {
            $count++
            $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fff"
            $occupied = if ((Get-Random -Maximum 2) -eq 0) { "true" } else { "false" }
            $payload = "{`"sensor_id`":`"$sensorId`",`"occupied`":$occupied,`"timestamp`":`"$ts`",`"seq`":$count}"

            # 전체 경로로 호출, 에러 캡처
            $result = & $mosqBin -h $h -p $p -t $topic -m $payload -i $clientId -q 1 2>&1
            if ($LASTEXITCODE -ne 0) {
                $failCount++
                Write-Output "FAIL seq=$count exit=$LASTEXITCODE msg=$result"
            }

            Start-Sleep -Seconds $interval
        }

        # Job 종료 시 센서별 요약 리턴
        Write-Output "SUMMARY $sensorId total=$count fail=$failCount"
    } -ArgumentList $MosquittoPub, $BrokerHost, $BrokerPort, $Topic, $ClientId, $IntervalSec, $EndTime, $SensorId

    $Jobs += $Job
    Write-Host "Started: $SensorId"
}

Write-Host ""
Write-Host "Running for ${DurationSec}s..."

Wait-Job -Job $Jobs -Timeout ($DurationSec + 30) | Out-Null

# 결과 출력 (실패/요약)
Write-Host ""
Write-Host "=== Results ==="
foreach ($j in $Jobs) {
    Receive-Job -Job $j
}

Remove-Job -Job $Jobs -Force
Write-Host ""
Write-Host "Done"