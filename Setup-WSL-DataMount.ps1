<#
WSL2 자동 마운트 시스템 부트스트랩 — Windows측 일괄 설정.

PC 초기화 후 또는 다른 머신에서 동일 구성을 재현할 때 한 번 실행한다.
SerialNumber, 라벨, 크기 중 하나로 디스크를 동적 식별하므로 PhysicalDrive
번호와 친화명(FriendlyName)이 바뀌어도 동작한다.

실행 결과:
1. SAN 정책 OfflineShared 적용 (새 디스크 자동 Offline)
2. 대상 디스크를 즉시 Offline으로 전환
3. C:\ProgramData\WSL\에 Mount-WSLDisk.ps1, Register-WSLMount.ps1 배치 (BOM 보존)
4. 작업 스케줄러 WSL_Mount_DataNVMe 등록 (Highest 권한, 로그온 트리거)
5. 즉시 1회 트리거하여 부착 검증

사용 예:
  # SerialNumber 명시 (가장 안정적)
  .\Setup-WSL-DataMount.ps1 -SerialNumber '<SN>' -Force

  # 라벨로 자동 감지 (디스크가 이미 ext4 라벨로 포맷된 경우)
  .\Setup-WSL-DataMount.ps1 -PartitionLabel 'wsldata' -Force

  # 후보 디스크만 조회
  .\Setup-WSL-DataMount.ps1 -ListCandidates
#>

[CmdletBinding(DefaultParameterSetName='BySerial')]
param(
    [Parameter(ParameterSetName='BySerial')]
    [string]$SerialNumber,

    [Parameter(ParameterSetName='ByLabel')]
    [string]$PartitionLabel,

    [Parameter(ParameterSetName='BySize')]
    [int]$DiskSizeGB,

    [Parameter(ParameterSetName='List')]
    [switch]$ListCandidates,

    [string]$DistroName = 'Ubuntu',

    [string]$InstallDir = 'C:\ProgramData\WSL',

    [string]$TaskName = 'WSL_Mount_DataNVMe',

    [switch]$Force,

    [switch]$SkipImmediateTrigger
)

$ErrorActionPreference = 'Stop'

function Write-Info  { param([string]$m) Write-Host "[INFO]  $m" -ForegroundColor Cyan }
function Write-Warn  { param([string]$m) Write-Host "[WARN]  $m" -ForegroundColor Yellow }
function Write-Err   { param([string]$m) Write-Host "[ERROR] $m" -ForegroundColor Red }
function Write-OK    { param([string]$m) Write-Host "[OK]    $m" -ForegroundColor Green }

# --- self-elevation ---
$cur = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($cur)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warn 'Administrator 권한이 필요합니다. UAC를 통해 재실행합니다.'
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$($MyInvocation.MyCommand.Path)`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "`"$v`"" }
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait
    exit $LASTEXITCODE
}

Write-Info "실행 컨텍스트: User=$env:USERNAME, Admin=True"
Write-Info "스크립트 위치: $PSScriptRoot"

# --- 환경 사전 점검 ---
Write-Info '--- 환경 사전 점검 ---'

# WSL 존재
try {
    $null = & wsl.exe --version 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'wsl.exe 미동작' }
    Write-OK 'WSL2 설치 확인'
} catch {
    Write-Err 'WSL2가 설치되지 않았거나 동작하지 않습니다.'
    Write-Host '  조치: `wsl --install` 실행 후 재부팅하고 본 스크립트를 다시 실행하십시오.'
    exit 1
}

# distro 존재
$distroList = & wsl.exe -l -q 2>&1 | ForEach-Object { ($_ -replace "`0",'').Trim() } | Where-Object { $_ }
if (-not ($distroList -icontains $DistroName)) {
    Write-Err "WSL distro '$DistroName' 가 설치되지 않았습니다."
    Write-Host "  설치 목록: $($distroList -join ', ')"
    Write-Host "  조치: `wsl --install -d $DistroName` 실행 후 본 스크립트를 다시 실행하십시오."
    exit 1
}
Write-OK "distro '$DistroName' 존재"

# 동일 디렉터리에 자산 두 개가 있는가
$mountSrc    = Join-Path $PSScriptRoot 'Mount-WSLDisk.ps1'
$registerSrc = Join-Path $PSScriptRoot 'Register-WSLMount.ps1'
if (-not (Test-Path $mountSrc))    { Write-Err "필수 파일 누락: $mountSrc"; exit 1 }
if (-not (Test-Path $registerSrc)) { Write-Err "필수 파일 누락: $registerSrc"; exit 1 }
Write-OK '필수 스크립트 두 개 확인'

# BOM 보장 (한글 주석 안전)
function Ensure-Bom {
    param([string]$Path)
    $b = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if (-not $hasBom) {
        $bom = [byte[]](0xEF,0xBB,0xBF)
        $new = New-Object byte[] ($b.Length + 3)
        [Array]::Copy($bom,0,$new,0,3)
        [Array]::Copy($b,0,$new,3,$b.Length)
        [System.IO.File]::WriteAllBytes($Path,$new)
        Write-Info "BOM 추가: $Path"
    }
}
Ensure-Bom -Path $mountSrc
Ensure-Bom -Path $registerSrc

# --- 디스크 식별 ---
Write-Info '--- 디스크 식별 ---'

function Get-DiskCandidates {
    Get-Disk | Where-Object { $_.BusType -ne $null } | ForEach-Object {
        [PSCustomObject]@{
            Number       = $_.Number
            Friendly     = $_.FriendlyName
            SerialTrim   = if ($_.SerialNumber) { $_.SerialNumber.Trim() } else { '' }
            IsOffline    = $_.IsOffline
            BusType      = $_.BusType
            SizeGB       = [math]::Round($_.Size / 1GB, 1)
            PartStyle    = $_.PartitionStyle
        }
    }
}

if ($ListCandidates) {
    Write-Info '시스템의 모든 디스크 (후보 식별용):'
    Get-DiskCandidates | Format-Table -AutoSize
    Write-Info "Ubuntu lsblk (이미 부착된 디스크의 라벨/UUID 확인용):"
    & wsl.exe -d $DistroName -- lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID 2>&1
    exit 0
}

$candidates = Get-DiskCandidates
$target = $null

switch ($PSCmdlet.ParameterSetName) {
    'BySerial' {
        if (-not $SerialNumber) {
            Write-Err '디스크 식별 인자 누락. -SerialNumber, -PartitionLabel, -DiskSizeGB 중 하나를 지정하거나 -ListCandidates로 후보를 확인하십시오.'
            exit 1
        }
        $needle = $SerialNumber.Trim()
        $target = $candidates | Where-Object { $_.SerialTrim -ieq $needle }
        if (-not $target) {
            $target = $candidates | Where-Object { $_.SerialTrim -ilike "*$needle*" }
        }
    }
    'ByLabel' {
        # WSL에서 라벨 매칭 디바이스를 찾아 SerialNumber 회수
        Write-Info "라벨 '$PartitionLabel' 자동 감지 시도 (distro=$DistroName)"
        $lsblkOut = & wsl.exe -d $DistroName -- lsblk -o NAME,FSTYPE,LABEL,SERIAL,MODEL -dn -P 2>&1 | Out-String
        # 라벨 일치 라인에서 SERIAL 추출
        $matchedSerial = $null
        $matchedModel  = $null
        foreach ($line in ($lsblkOut -split "`n")) {
            if ($line -match 'LABEL="([^"]*)"') {
                $lbl = $matches[1]
                if ($lbl -ieq $PartitionLabel) {
                    if ($line -match 'SERIAL="([^"]*)"') { $matchedSerial = $matches[1].Trim() }
                    if ($line -match 'MODEL="([^"]*)"')  { $matchedModel  = $matches[1].Trim() }
                    break
                }
            }
        }
        if ($matchedSerial) {
            Write-OK "라벨 매칭 SerialNumber=$matchedSerial (Model=$matchedModel)"
            $target = $candidates | Where-Object { $_.SerialTrim -ieq $matchedSerial }
        } else {
            Write-Warn '라벨 매칭 디바이스를 distro 내에서 찾지 못함. 디스크가 이미 부착되지 않았거나 미포맷일 수 있습니다.'
        }
    }
    'BySize' {
        $target = $candidates | Where-Object { [math]::Abs($_.SizeGB - $DiskSizeGB) -le 2 }
    }
}

if (-not $target) {
    Write-Err '대상 디스크를 식별하지 못했습니다.'
    Write-Info '현재 시스템 디스크 목록:'
    $candidates | Format-Table -AutoSize
    exit 1
}
if (@($target).Count -gt 1) {
    Write-Err '여러 후보가 매칭됩니다. 더 구체적인 인자로 재시도하십시오.'
    $target | Format-Table -AutoSize
    exit 1
}

$disk = Get-Disk -Number $target.Number
$resolvedSerial = $disk.SerialNumber.Trim()
Write-OK "대상 디스크: Number=$($disk.Number)  Model=$($disk.FriendlyName)  Serial='$resolvedSerial'  Size=$([math]::Round($disk.Size/1GB,1))GB  IsOffline=$($disk.IsOffline)"

if (-not $Force) {
    $resp = Read-Host "위 디스크에 대해 자동 마운트 시스템을 설정합니다. 계속하시겠습니까? [y/N]"
    if ($resp -notmatch '^[Yy]') { Write-Info '취소됨'; exit 0 }
}

# --- SAN 정책 ---
Write-Info '--- SAN 정책 적용 ---'
try {
    $cur = Get-StorageSetting -ErrorAction Stop
    Write-Info "현재 NewDiskPolicy=$($cur.NewDiskPolicy)"
    if ($cur.NewDiskPolicy -ne 'OfflineShared') {
        Set-StorageSetting -NewDiskPolicy OfflineShared -ErrorAction Stop
        Write-OK 'NewDiskPolicy → OfflineShared 설정'
    } else {
        Write-OK 'NewDiskPolicy 이미 OfflineShared'
    }
} catch {
    Write-Warn "SAN 정책 변경 실패: $($_.Exception.Message). 다음 단계는 진행."
}

# --- 디스크 Offline 전환 ---
Write-Info '--- 디스크 Offline 전환 ---'
if (-not $disk.IsOffline) {
    # 만약 wsl에 부착돼 있을 수도 있으므로 우선 unmount 시도 (실패 무시)
    & wsl.exe --unmount "\\.\PHYSICALDRIVE$($disk.Number)" 2>&1 | Out-Null
    Set-Disk -Number $disk.Number -IsOffline $true
    Start-Sleep -Seconds 1
    $disk = Get-Disk -Number $disk.Number
    Write-OK "Offline 전환: IsOffline=$($disk.IsOffline)"
} else {
    Write-OK '디스크 이미 Offline'
}

# --- 자산 배포 ---
Write-Info '--- 자산 배포 ---'
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
    Write-Info "디렉터리 생성: $InstallDir"
}
$mountDst    = Join-Path $InstallDir 'Mount-WSLDisk.ps1'
$registerDst = Join-Path $InstallDir 'Register-WSLMount.ps1'

# 기존 파일 백업
foreach ($pair in @(@($mountDst,$mountSrc), @($registerDst,$registerSrc))) {
    $dst,$src = $pair
    if (Test-Path $dst) {
        $ts = Get-Date -Format 'yyyyMMddHHmmss'
        Copy-Item -Force -Path $dst -Destination "$dst.bak-$ts"
        Write-Info "기존 파일 백업: $dst → $dst.bak-$ts"
    }
    Copy-Item -Force -Path $src -Destination $dst
}
Write-OK '두 스크립트 배치 완료'

# --- 작업 스케줄러 등록 (Register-WSLMount.ps1 호출) ---
Write-Info '--- 작업 스케줄러 등록 ---'
$registerArgs = @('-SerialNumber', $resolvedSerial, '-Force')
& $registerDst @registerArgs
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    Write-Err "Register-WSLMount.ps1 실패 (ExitCode=$LASTEXITCODE)"
    exit $LASTEXITCODE
}
Write-OK '작업 스케줄러 등록 완료'

# --- 즉시 검증 트리거 ---
if (-not $SkipImmediateTrigger) {
    Write-Info '--- 즉시 검증: 작업 스케줄러 1회 실행 ---'
    try {
        Start-ScheduledTask -TaskName $TaskName
        Start-Sleep -Seconds 6
        $info = Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo
        Write-Info "LastTaskResult=$($info.LastTaskResult)  LastRunTime=$($info.LastRunTime)"
        if ($info.LastTaskResult -eq 0) {
            Write-OK '부착 성공'
        } else {
            Write-Warn "스케줄러 비0 종료. mount.log 확인 필요: $InstallDir\mount.log"
        }
    } catch {
        Write-Warn "Start-ScheduledTask 실패: $($_.Exception.Message)"
    }
}

# --- 종합 보고 ---
Write-Host ''
Write-OK '=== Windows측 설정 완료 ==='
Write-Host "  대상 디스크 SerialNumber : $resolvedSerial"
Write-Host "  설치 디렉터리            : $InstallDir"
Write-Host "  작업 스케줄러            : $TaskName"
Write-Host ''
$shPath = Join-Path $PSScriptRoot 'Setup-Ubuntu-DataMount.sh'
$wslShPath = & wsl.exe -d $DistroName -- wslpath -a "$shPath" 2>$null
if ($LASTEXITCODE -ne 0 -or -not $wslShPath) { $wslShPath = $shPath }
Write-Host '다음 단계:'
Write-Host "  1. WSL에 진입: wsl -d $DistroName"
Write-Host "  2. Ubuntu측 부트스트랩 실행:"
Write-Host "     sudo bash $wslShPath"
Write-Host '  3. 검증: df -hT /mnt/data'
