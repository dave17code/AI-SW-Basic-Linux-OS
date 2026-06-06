# 🛡️ Linux 기반 시스템 관제 자동화 및 인프라 보안 환경 구축 보고서

본 보고서는 다중 사용자 엔지니어링 환경에서의 역할 기반 권한 제어(RBAC), 
인바운드 보안 통제 규칙, 애플리케이션 가동 무결성 확보 및 
시스템 리소스 모니터링 스크립트 자동화에 대한 최종 요구사항 수행 내역서입니다.

---

## 📑 1. 요구사항 수행 내역서

### 🔒 [보안 및 네트워크 통제]
- **SSH 인프라 강화**: 원격 접속 기본 포트를 `20022`로 포트 포워딩 변경 
  처리 완료하였으며, 외부 무차별 대입 공격(Brute Force)의 원천 차단을 위해 
  `/etc/ssh/sshd_config` 설정을 변경하여 **Root 원격 로그인(`PermitRootLogin no`)을 차단**했습니다.
- **최소 네트워크 차단막 정책**: 방화벽 엔진(`UFW`)을 활성화한 뒤, 
  승인된 관리 포트인 **TCP 20022 (SSH)** 및 서비스 통신 규격 포트인 
  **TCP 15034 (APP)** 포트 2개만을 인바운드 허용 리스트로 고정했습니다.

### 👥 [계정/그룹 권한 체계 및 ACL 인프라 설계]
- **역할 기반 사용자 그룹 분리**:
  - `agent-admin`: 자동화 크론 로봇(`crontab`)의 단독 실행자이자 모니터링 주체.
  - `agent-dev`: 관제 핵심 코드인 `monitor.sh`를 설계한 개발 권한 계정.
  - `agent-test`: 자원 모니터링 대상 구역의 샌드박스를 확인하는 QA 계정.
- **보안 디렉터리 격리 정책**: 공용 자산 디렉터리는 `agent-common` 그룹에 
  개방하되, 핵심 암호화 통제 장소인 `$AGENT_HOME/api_keys` 및 시스템 중앙 로그 
  수집소인 `/var/log/agent-app`은 철저히 **`agent-core` 그룹 ONLY**의 
  R/W 권한만 허용하여 권한 탈취 리스크를 완벽하게 배제했습니다.

### 🚀 [애플리케이션 가동 및 부트 시퀀스 통과]
- **보안 암호문 매칭 우회**: 앱 실행 즉시 파이썬 바이너리가 정적 탐색하는 
  고정 경로 `$AGENT_HOME/api_keys/t_secret.key`를 정석대로 매핑하고, 
  내부 지시 스트링인 `agent_api_key_test`를 정확히 1줄로 주입 완료했습니다.
- **검증 완료**: 일반 계정 신분으로 환경 변수 5형제를 동기화하여 구동한 결과, 
  독점적인 내부 검증 시퀀스가 모두 **[OK]** 사인을 반환하며 `0.0.0.0:15034` 
  대기 상태인 **"Agent READY"** 플래그를 정상 확인했습니다.

---

## 🛠️ 2. 설정 및 명령어 기록 (History)

### 1) SSH 인프라 및 방화벽 규칙 세팅
```bash
# SSH 환경 설정 및 시스템 소켓 간섭 해제
sudo apt update && \
sudo apt install nano openssh-server bc ufw -y

sudo systemctl stop ssh.socket && \
sudo systemctl disable ssh.socket

sudo pkill -f sshd && \
sudo service ssh restart

# 최소 보안 포트 인바운드 허용
sudo ufw allow 20022/tcp
sudo ufw allow 15034/tcp
sudo ufw enable
```

### 2) 계정 / 그룹 / ACL 권한 격리 공사
```bash
# 보안 그룹 및 역할 기반 유저 생성
sudo groupadd agent-common
sudo groupadd agent-core

sudo useradd -m -g agent-common \
  -G agent-core -s /bin/bash agent-admin
sudo useradd -m -g agent-common \
  -G agent-core -s /bin/bash agent-dev
sudo useradd -m -g agent-common \
  -s /bin/bash agent-test

# 절대 경로 기준 디렉터리 권한 및 소유권 제약
sudo chown agent-dev:agent-common \
  /home/agent-dev/agent-app/upload_files
sudo chmod 770 \
  /home/agent-dev/agent-app/upload_files

sudo chown agent-dev:agent-core \
  /home/agent-dev/agent-app/api_keys
sudo chmod 770 \
  /home/agent-dev/agent-app/api_keys

# 중앙 로그 저장소 권한 격리
sudo mkdir -p /var/log/agent-app
sudo chown -R root:agent-core /var/log/agent-app
sudo chmod -R 770 /var/log/agent-app
```

### 3) 샌드박스 환경 변수 주입 (`.bashrc`)
```bash
export AGENT_HOME="/home/agent-dev/agent-app"
export AGENT_PORT="15034"
export AGENT_UPLOAD_DIR="/home/agent-dev/agent-app/upload_files"
export AGENT_KEY_PATH="/home/agent-dev/agent-app/api_keys/t_secret.key"
export AGENT_LOG_DIR="/var/log/agent-app"
```

---

## 📜 3. 자동화 스크립트 소스코드 (`monitor.sh`)

```bash
#!/bin/bash

if [ -z "$AGENT_HOME" ]; then
    AGENT_HOME="/home/agent-dev/agent-app"
fi

LOG_DIR="/var/log/agent-app"
LOG_FILE="$LOG_DIR/monitor.log"
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# 1. 프로세스 가동 무결성 검사
PID=$(pgrep -f "agent-app-linux" | paste -sd "," -)
if [ -z "$PID" ]; then
    echo "[$TIMESTAMP] [ERROR] Process not running." >> "$LOG_FILE"
    exit 1
fi

# 2. 관제 서비스 포트 바인딩 검사
PORT_CHECK=$(ss -tln | grep -w "15034")
if [ -z "$PORT_CHECK" ]; then
    echo "[$TIMESTAMP] [ERROR] Port 15034 closed." >> "$LOG_FILE"
    exit 1
fi

# 3. 시스템 하드웨어 리소스 파싱
CPU_IDLE=$(top -bn1 | grep "Cpu(s)" | awk '{print $8}')
CPU_USED=$(echo "100 - $CPU_IDLE" | bc)
CPU_INT=$(echo "$CPU_USED" | awk '{print int($1)}')
MEM_USED=$(free | grep Mem | awk '{print int($3/$2 * 100)}')
DISK_USED=$(df / | tail -1 | awk '{print $5}' | tr -d '%')

# 임계치 초과 시 경고 핸들링
if [ "$CPU_INT" -gt 20 ]; then 
    echo "[$TIMESTAMP] [WARNING] CPU exceeded 20% (${CPU_INT}%)" >> "$LOG_FILE"
fi
if [ "$MEM_USED" -gt 10 ]; then 
    echo "[$TIMESTAMP] [WARNING] MEM exceeded 10% (${MEM_USED}%)" >> "$LOG_FILE"
fi
if [ "$DISK_USED" -gt 80 ]; then 
    echo "[$TIMESTAMP] [WARNING] DISK exceeded 80% (${DISK_USED}%)" >> "$LOG_FILE"
fi

# 표준 관제 포맷 로그 축적
echo "[$TIMESTAMP] PID:$PID CPU:${CPU_INT}% MEM:${MEM_USED}% DISK:${DISK_USED}%" \
    >> "$LOG_FILE"

# 로그 파일 로테이션 (10MB 제한)
if [ -f "$LOG_FILE" ]; then
    FILE_SIZE=$(wc -c < "$LOG_FILE")
    MAX_SIZE=$((10 * 1024 * 1024))
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
        mv "$LOG_FILE" "${LOG_FILE}.old" && touch "$LOG_FILE"
        sudo chown root:agent-core "$LOG_FILE"
        sudo chmod 660 "$LOG_FILE"
    fi
fi
```

---

## 📋 4. 필수 증거 자료 체크리스트 및 실시간 증적

### 📸 1) SSH 포트 변경(20022) 및 Root 원격 접속 차단 설정 확인 내역
> **체크리스트:** `sshd_config` 보안 필터 결과 및 20022 포트 리슨 상태 (수행: dave)
```bash
sudo grep -E "Port|PermitRootLogin" /etc/ssh/sshd_config | grep -v '^#'
sudo ss -tulnp | grep ssh
```
<img width="918" height="135" alt="01_ssh" src="https://github.com/user-attachments/assets/53b9f6c3-65cc-4d0b-a78b-82060afc7e5c" />

---

### 📸 2) 방화벽(UFW) 활성화 및 20022/tcp, 15034/tcp만 허용 내역
> **체크리스트:** 인바운드 통제 및 지정 포트 외의 전체 Deny 정책 검증 (수행: dave)
```bash
sudo ufw status verbose
```
<img width="598" height="305" alt="02_ufw" src="https://github.com/user-attachments/assets/394128b8-5c98-4d39-94ac-ab1dfd4c7fc2" />

---

### 📸 3) 계정/그룹(agent-admin/dev/test, agent-common/core) 생성 확인 내역
> **체크리스트:** 유저별 고유 신분 배지 및 소속 보안 그룹 권한 체계 검증 (수행: agent-admin)
```bash
id agent-admin; id agent-dev; id agent-test
```
<img width="820" height="93" alt="03_accounts" src="https://github.com/user-attachments/assets/b3559035-a759-4141-854b-a52621834643" />

---

### 📸 4) 디렉토리 구조 및 권한(ACL 포함) 확인 내역
> **체크리스트:** 절대 경로 내부 폴더별 소유권 및 `770` 자물쇠 상태 확인 (수행: agent-admin)
```bash
ls -l /home/agent-dev/agent-app
```
![디렉토리 권한 확인](docs/screenshots/04_dir_permission.png)

---

### 📸 5) 앱 Boot Sequence 5단계 [OK] 및 “Agent READY” 확인 내역
> **체크리스트:** 파이썬 x86 바이너리의 내부 검증 통과 로그 및 READY 플래그 (수행: agent-dev)
```bash
$AGENT_HOME/agent-app-linux-x86
```
![앱 부트 시퀀스 확인](docs/screenshots/05_app_boot.png)

---

### 📸 6) `monitor.sh` 실행 결과(프로세스/포트/리소스/경고) 내역
> **체크리스트:** 자원 수집 스크립트를 수동 1회 가동하여 정상 파싱 처리되는지 확인 (수행: agent-dev)
```bash
/home/agent-dev/agent-app/bin/monitor.sh
```
![스크립트 실행 결과 확인](docs/screenshots/06_script_test.png)

---

### 📸 7) crontab 매분 실행 등록 및 자동 실행 확인(1분 후 로그 증가) 내역
> **체크리스트:** 크론 정기 스케줄러 장부에 매분(`* * * * *`) 로봇 상주 검증 (수행: agent-admin)
```bash
crontab -l
```
![크론탭 등록 확인](docs/screenshots/07_cron_setting.png)

---

### 📸 8) /var/log/agent-app/monitor.log 누적 기록 확인(최근 라인) 내역
> **체크리스트:** 크론 로봇 가동 후 로그 파일의 관제 라인이 실시간 누적되는지 추적 (수행: agent-admin)
```bash
tail -f /var/log/agent-app/monitor.log
```
![로그 누적 기록 확인](docs/screenshots/08_monitor_log.png)
