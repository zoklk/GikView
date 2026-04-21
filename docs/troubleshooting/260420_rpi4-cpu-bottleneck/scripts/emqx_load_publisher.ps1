# emqx_load_publisher.ps1
# MQTT 부하 테스트 - 9개 센서를 병렬로 publish

param(
    [string]$BrokerHost = "172.17.89.130",
    [int]$BrokerPort = 11883,
    [int]$SensorCount = 9,
    [int]$IntervalSec = 5,
    [int]$DurationSec = 300
)

# mosquitto 경로
$MosquittoDir = "C:\Program Files\mosquitto"
if (-not ($env:Path -split ';' -contains $MosquittoDir)) {
    $env:Path += ";$MosquittoDir"
}

if (-not (Get-Command mosquitto_pub -ErrorAction SilentlyContinue)) {
    Write-Error "mosquitto_pub not found in $MosquittoDir"
    exit 1
}

$EndTime = (Get-Date).AddSeconds($DurationSec)

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
        param($h, $p, $topic, $clientId, $interval, $endTime, $sensorId)

        $count = 0
        while ((Get-Date) -lt $endTime) {
            $count++
            $ts = Get-Date -Format "yyyy-MM-ddTHH:mm:ss.fff"
            $occupied = if ((Get-Random -Maximum 2) -eq 0) { "true" } else { "false" }
            $payload = "{`"sensor_id`":`"$sensorId`",`"occupied`":$occupied,`"timestamp`":`"$ts`",`"seq`":$count}"

            & mosquitto_pub -h $h -p $p -t $topic -m $payload -i $clientId -q 1 2>&1 | Out-Null

            Start-Sleep -Seconds $interval
        }
    } -ArgumentList $BrokerHost, $BrokerPort, $Topic, $ClientId, $IntervalSec, $EndTime, $SensorId

    $Jobs += $Job
    Write-Host "Started: $SensorId"
}

Write-Host ""
Write-Host "Running for ${DurationSec}s..."

Wait-Job -Job $Jobs -Timeout ($DurationSec + 30) | Out-Null
Remove-Job -Job $Jobs -Force

Write-Host "Done"