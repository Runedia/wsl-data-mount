# WSL2 Data Mount — 재현 가능한 자동 마운트 시스템

WSL2 패스스루 마운트 시스템(`PHYSICALDRIVE → /mnt/data`)을 새 PC 또는 포맷 후 환경에서 한 번에 재구축하기 위한 자산 번들.

## 디스크 정보

본 저장소는 환경 비종속. 로컬 디스크의 SerialNumber·UUID 등은 `LOCAL.md`에 사용자가 별도 기록(파일은 `.gitignore`로 추적 제외). 템플릿은 [`LOCAL.md.example`](LOCAL.md.example) 참고.

| 항목 | 사용 위치 |
|---|---|
| SerialNumber | `Setup-WSL-DataMount.ps1 -SerialNumber '<SN>'` |
| 파티션 라벨 (기본 `wsldata`) | `--label`로 재정의 |
| UUID | 부트스트랩이 자동 추출, 직접 지정 불필요 |
| 마운트 지점 (기본 `/mnt/data`) | `--mount-point`로 재정의 |

## 번들 파일

```
wsl-data-mount/
  Setup-WSL-DataMount.ps1     ← Windows 부트스트랩 (관리자 권한, self-elevation)
  Setup-Ubuntu-DataMount.sh   ← Ubuntu 부트스트랩 (sudo)
  Mount-WSLDisk.ps1           ← 런타임 래퍼 (Setup-WSL이 ProgramData로 복사)
  Register-WSLMount.ps1       ← 작업 스케줄러 등록 (Setup-WSL이 내부 호출)
  README.md                   ← 본 문서
  LOCAL.md.example            ← 사용자 디스크 정보 기록 템플릿
  .gitignore .gitattributes
  skills/
    wsl-data-mount-setup/SKILL.md   ← Claude Code skill (선택적으로 ~/.claude/skills/로 junction)
```

본 저장소는 임의 위치로 clone 또는 USB 백업 가능. 모든 스크립트는 자기 자신 디렉터리에서 동료 파일을 찾으므로 **함께 두기만 하면 동작**.

## 사전 요건

1. **Windows 11/10 + WSL2 활성화** (`wsl --install`)
2. **Ubuntu distro 설치** (`wsl --install -d Ubuntu`) — 처음 실행 시 사용자 계정 생성. 이름은 자유, 부트스트랩은 `$SUDO_USER`로 감지
3. **데이터 디스크 물리 연결** — SATA/NVMe, USB-외장도 가능

## 절차

### 1) Windows 측 (관리자 권한 자동)

```powershell
# 저장소가 있는 디렉터리로 이동
cd <repo-path>   # 예: E:\Project\wsl-data-mount

# 후보 디스크 확인 (선택)
.\Setup-WSL-DataMount.ps1 -ListCandidates

# 본 설정 — <SN> 자리에 본인의 SerialNumber
.\Setup-WSL-DataMount.ps1 -SerialNumber '<SN>' -Force
```

UAC 1회 승인. 약 10초 내 완료. 종료 시점에 `LastTaskResult=0`이면 디스크가 WSL VM에 부착됨.

**SerialNumber를 모를 경우**:
```powershell
# 기존 ext4 라벨(예: wsldata)로 식별
.\Setup-WSL-DataMount.ps1 -PartitionLabel 'wsldata' -Force

# 크기로 식별 (±2GB)
.\Setup-WSL-DataMount.ps1 -DiskSizeGB <GB> -Force
```

### 2) Ubuntu 측 (WSL 내부)

`Setup-WSL-DataMount.ps1` 종료 시 안내되는 wslpath를 그대로 복사해 sudo로 실행. 예:

```bash
wsl -d Ubuntu
sudo bash /mnt/<drive>/<path>/wsl-data-mount/Setup-Ubuntu-DataMount.sh
```

기존 데이터를 보존하면서 라벨 자동 탐지. 매개변수 무인자.

**신규 디스크 (데이터 없음)** — 포맷부터 진행:
```bash
sudo bash Setup-Ubuntu-DataMount.sh --force-format --yes
```

**변경 사전 검토만**:
```bash
sudo bash Setup-Ubuntu-DataMount.sh --dry-run
```

### 3) 최종 검증

```powershell
wsl --shutdown
wsl -d Ubuntu -- df -hT /mnt/data
```

기대 출력:
```
Filesystem     Type  Size  Used Avail Use% Mounted on
/dev/sd?1      ext4  <size> ...                /mnt/data
```

### 4) 재부팅 검증

Windows 재부팅 후 다시 `wsl -d Ubuntu -- df -hT /mnt/data`. 동일 결과면 자동화 완성.

## Skill 사용 (Claude Code)

`skills/wsl-data-mount-setup/SKILL.md`에 동일 절차의 Claude Code 가이드가 포함되어 있다. Claude Code가 인식하게 하려면 `~/.claude/skills/wsl-data-mount-setup`을 본 디렉터리로 연결:

```powershell
# 디렉터리 junction (admin 불필요)
New-Item -ItemType Junction `
  -Path "$env:USERPROFILE\.claude\skills\wsl-data-mount-setup" `
  -Target "$(Resolve-Path .\skills\wsl-data-mount-setup)"
```

또는 단순히 SKILL.md 사본을 그 경로에 복사.

## 멱등성

두 부트스트랩 모두 반복 실행해도 상태 누적 없음. 기존 파일은 `.bak-<timestamp>`로 자동 백업.

## 일반적 함정

| 증상 | 조치 |
|---|---|
| `Mount-WSLDisk.ps1`가 ALREADY_ATTACHED 후에도 ExitCode=-1로 실패 | 본 번들의 패치판은 인코딩 정규화로 해결됨. 이전 버전이면 본 파일로 교체 |
| `wsl --shutdown` 후 `wsl` 재진입하면 `/mnt/data` 미마운트 | 디스크가 VM 종료와 함께 detach. `Start-ScheduledTask -TaskName 'WSL_Mount_DataNVMe'` |
| 기본 distro가 `docker-desktop` | `wsl --set-default Ubuntu` |
| 재부팅 후 Windows가 데이터 디스크를 Online으로 복원 | SAN 정책 미적용. Setup-WSL이 OfflineShared 적용하므로 재실행 |

## 워크플로 분리 (권장)

- **Windows 측 LLM 도구** (Ollama, LM Studio, Docker): 각자 다운로드, WSL 내 모델 미접근
- **WSL 측 LLM 도구** (vLLM, llama.cpp): `/mnt/data`의 모델만 사용
- 중복 다운로드 의식적으로 수용
