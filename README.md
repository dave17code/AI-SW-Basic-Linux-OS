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
# =========================================================================
# [문법 해설] 쉬뱅 (Shebang - #!)
# 스크립트 맨 첫 줄에 작성하는 절대 규칙입니다. 이 파일이 실행될 때 
# 리눅스 커널에게 "밑에 적힌 코드들을 /bin/bash 해석기(셸)로 실행해라"라고 
# 명시적으로 지정하는 장치입니다.
# =========================================================================

# =========================================================================
# 1. 환경변수 및 기본 장부(로그) 설정 영역
# =========================================================================

# [문법] if [ -z "$변수" ]; then ... fi
# - if [ ... ]문에서 대괄호([ ]) 양 끝에는 반드시 '공백(띄어쓰기)'이 있어야 합니다.
# - -z 연산자: "Zero"의 약자로, 뒤에 오는 변수의 내용물이 '텅 비어있는지' 검사합니다.
# - 변수를 호출할 때 쌍따옴표("$AGENT_HOME")로 감싸주는 것이 공백 문자 오작동을 막는 실무 정석입니다.
if [ -z "$AGENT_HOME" ]; then
    # 변수가 비어있다면 대입 연산자(=)를 통해 기본 경로를 주머니에 집어넣습니다.
    # ⚠️ 주의: 리눅스에서 변수를 대입할 때는 '=' 기호 앞뒤로 절대 공백(띄어쓰기)이 있으면 안 됩니다!
    AGENT_HOME="/home/agent-dev/agent-app"
fi

LOG_DIR="/var/log/agent-app"
LOG_FILE="$LOG_DIR/monitor.log"

# [문법] $(date "+포맷") 명령어 치환 및 날짜 출력
# - $( ) 기호: 괄호 안의 리눅스 명령어를 실행한 '최종 텍스트 결과물'을 가로채는 치트키입니다.
# - date 명령어에 더하기(+) 포맷을 주어 "년-월-일 시:분:초" 형태로 타임스탬프 도장을 만듭니다.
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")


# [문법] if [ ! -d "$변수" ]; then ... fi
# - -d 연산자: 뒤에 오는 경로가 "Directory(폴더)"가 맞는지 검사합니다.
# - ! 기호: NOT(부정)의 뜻으로, 즉 "만약 로그 폴더가 존재하지 않는다면"이라는 조건이 됩니다.
if [ ! -d "$LOG_DIR" ]; then
    # mkdir -p: 상위 폴더가 없으면 상위 폴더까지 한 번에 줄줄이 만들어주는 하이패스 옵션입니다.
    sudo mkdir -p "$LOG_DIR"
    # chown: 소유자와 그룹을 변경합니다. (소유자는 root, 그룹은 관제 전용 agent-core)
    sudo chown root:agent-core "$LOG_DIR"
    # chmod 775: 소유자(rwx=7), 그룹(rwx=7), 일반타인(rx=5)에게 권한을 부여하여 공유 폴더로 만듭니다.
    sudo chmod 775 "$LOG_DIR"
fi

# =========================================================================
# 2. [미션 1] 프로세스 가동 무결성 검사 (생명줄 체크)
# =========================================================================

# [문법] pgrep과 paste 명령어의 파이프라인(|) 연결
# - pgrep -f: 메모리에서 실행 중인 프로세스 중 해당 문자열이 포함된 녀석의 주민번호(PID)만 찾아 뽑아냅니다.
# - | (파이프): 앞 명령어의 출력 데이터를 화면에 안 보여주고, 뒤 명령어의 입력 데이터로 실시간 토스합니다.
# - paste -sd "," -: 파이프로 넘어온 표준 입력 데이터(-)가 여러 줄일 때, 줄바꿈을 지우고 쉼표(",")로 한 줄로 이어붙입니다.
#   예시: 프로세스가 2개면 "1514\n1515"로 나오는 데이터를 "1514,1515"라는 하나의 예쁜 텍스트로 가공합니다.
PID=$(pgrep -f "agent-app-linux" | paste -sd "," -)

if [ -z "$PID" ]; then
    # [문법] >> (Append - 이어쓰기 리다이렉션)
    # 기호 앞에 있는 echo의 출력 텍스트 데이터를 화면에 뿜지 않고, $LOG_FILE 파일 맨 아랫줄에 '누적'하여 추가합니다.
    echo "[$TIMESTAMP] [ERROR] Process not running." >> "$LOG_FILE"
    
    # [문법] exit 1 (비상 탈출 종료 코드)
    # 리눅스 시스템에게 "이 스크립트는 에러(1)가 발생해서 도중에 기절했다"고 보고하며 스크립트를 즉시 종료합니다.
    # 엔진이 죽었으므로 밑에 있는 포트나 하드웨어 검사 코드는 실행할 필요가 없기 때문에 여기서 끊어주는 것입니다.
    exit 1
fi

# =========================================================================
# 3. [미션 2] 관제 서비스 포트 바인딩 검사 (통신로 체크)
# =========================================================================

# [문법] ss 명령어와 grep -w 옵션
# - ss -tln: TCP 프로토콜(-t)이면서 외부 손님을 목 빼고 기다리는 Listening(-l) 상태의 포트를 순수 숫자(-n)로 조회합니다.
# - grep -w "15034": 정확히 "15034"라는 독립된 단어/숫자와 통째로 일치하는 줄만 장부에서 칼같이 낚아챕니다.
#   (-w 옵션이 없으면 150345나 215034 같은 다른 포트가 켜져 있어도 정상이라고 오판하는 대참사가 납니다.)
PORT_CHECK=$(ss -tln | grep -w "15034")

if [ -z "$PORT_CHECK" ]; then
    echo "[$TIMESTAMP] [ERROR] Port 15034 closed." >> "$LOG_FILE"
    exit 1
fi

# =========================================================================
# 4. [미션 3] 시스템 하드웨어 리소스 파싱 (고급 문자열 도려내기)
# =========================================================================

# --- 1) CPU 사용량 추출 원리 (vmstat 경량화 버전 적용) ---
# - vmstat 1 2: 1초 간격으로 장부를 총 2번 출력합니다. (첫 줄은 과거 평균, 두 번째 줄이 진짜 실시간 값)
# - tail -1: 가장 마지막에 측정된 따끈따끈한 실시간 데이터 행만 가로챕니다.
# - awk '{print $15}': 공백 기준 15번째 덩어리인 'id' (Idle - 아무것도 안 하고 노는 CPU 비율 %) 값만 정수로 쏙 도려냅니다.
CPU_IDLE=$(vmstat 1 2 | tail -1 | awk '{print $15}')

# [문법] $(( )) 산술 확장 (Arithmetic Expansion)
# vmstat은 처음부터 소수점이 없는 깨끗한 '정수'를 뱉어내기 때문에, 무거운 bc 계산기나 awk int()를 쓸 필요가 없습니다.
# 셸 스크립트 자체 메모리 성능만으로 100 - Idle 연산을 초고속 처리하여 실제 CPU 사용량 정수(%)를 단 한 줄로 도출합니다.
CPU_INT=$((100 - CPU_IDLE))


# --- 2) 메모리 사용량 추출 원리 ---
# - free: 현재 시스템 메모리 상태판을 출력합니다.
# - grep Mem: 실제 물리 메모리가 적힌 행만 가져옵니다. (출력 예시: Mem: 16000 4000 12000 ...)
# - awk '{print int($3/$2 * 100)}': 3번째 덩어리(사용 중인 메모리 $3)를 2번째 덩어리(전체 메모리 $2)로 나눈 뒤 100을 곱해 퍼센트 정수로 뽑아냅니다.
MEM_USED=$(free | grep Mem | awk '{print int($3/$2 * 100)}')


# --- 3) 디스크 사용량 추출 원리 ---
# - df /: 최상위 루트디스크의 용량 장부를 뽑습니다.
# - tail -1: 첫 줄에 나오는 제목 행(Filesystem... 용량...)을 버리고, 맨 아랫줄의 실제 데이터 행만 선택합니다.
# - awk '{print $5}': 5번째 덩어리인 사용량 퍼센트(예시: "45%")를 가져옵니다.
# - tr -d '%': "Delete" 옵션으로 글자 뒤에 달라붙어 있는 퍼센트(%) 기호를 가위로 자르듯 도려내어 순수 숫자 "45"만 남깁니다.
DISK_USED=$(df / | tail -1 | awk '{print $5}' | tr -d '%')

# =========================================================================
# 5. [미션 4] 임계치 초과 시 경고 핸들링
# =========================================================================

# [문법] -gt (Greater Than - 초과 비교 연산자)
# - 리눅스 셸에서는 부등호(>, <) 대신 문자로 된 연산자를 씁니다.
# - -gt: "A가 B보다 크다면(초과)", -lt: 미만, -eq: 같다, -ne: 다르다
if [ "$CPU_INT" -gt 20 ]; then 
    echo "[$TIMESTAMP] [WARNING] CPU exceeded 20% (${CPU_INT}%)" >> "$LOG_FILE"
fi

if [ "$MEM_USED" -gt 10 ]; then 
    echo "[$TIMESTAMP] [WARNING] MEM exceeded 10% (${MEM_USED}%)" >> "$LOG_FILE"
fi

if [ "$DISK_USED" -gt 80 ]; then 
    echo "[$TIMESTAMP] [WARNING] DISK exceeded 80% (${DISK_USED}%)" >> "$LOG_FILE"
fi

# =========================================================================
# 6. [미션 5] 표준 관제 포맷 로그 실시간 축적
# =========================================================================
# [문법] \ (Line Continuation - 행 연속 기호)
# 코드가 너무 길어져서 가독성을 위해 줄바꿈을 할 때, 맨 뒤에 역슬래시(\)를 붙여주면 
# 리눅스 커널이 "아, 밑에 줄 코드랑 끊어지지 않고 쭉 이어지는 한 문장이구나" 하고 인식합니다.
echo "[$TIMESTAMP] PID:$PID CPU:${CPU_INT}% MEM:${MEM_USED}% DISK:${DISK_USED}%" \
    >> "$LOG_FILE"

# =========================================================================
# 7. [미션 6] 롤링 로그 로테이션 자동화 (10MB 제한 및 최대 10개 유지)
# =========================================================================

# [문법] -f 연산자
# 뒤에 오는 경로가 실제로 존재하는 "File(파일)"이 맞는지 검사합니다.
if [ -f "$LOG_FILE" ]; then

    # [문법] wc -c < 파일 (파일 용량 측정 기법)
    # - wc -c 명령어는 파일의 byte 용량을 측정해 줍니다.
    # - 이때 < 기호(입력 리다이렉션)를 쓰면 파일명 출력 없이 '순수 용량 숫자'만 리턴해주어 변수에 깔끔하게 담깁니다.
    FILE_SIZE=$(wc -c < "$LOG_FILE")
    
    # [문법] $(( )) 산술 확장 (Arithmetic Expansion)
    # 리눅스 셸 내부에서 곱하기(*), 더하기(+) 같은 순수 정수 수학 연산을 직접 처리해 주는 기호입니다.
    # 10MB를 컴퓨터가 이해하는 바이트(Byte) 단위 공식으로 변환한 것입니다. (10 * 1024 * 1024 = 10485760 바이트)
    MAX_SIZE=$((10 * 1024 * 1024))

    # 현재 장부 크기가 10MB 한계치 숫자를 초과(-gt)했다면 압축/로테이션 공사를 시작합니다.
    if [ "$FILE_SIZE" -gt "$MAX_SIZE" ]; then
    
        # [1단계] 원본 1개 + 백업본 9개 = 총 10개만 유지하는 한계선 방어 규칙
        # 만약 이미 제일 늙은 9번째 과거 백업 파일(monitor.log.9)이 세상에 있다면, 
        # 총 개수 10개를 유지해야 하므로 rm(Remove) 명령어로 과감하게 지워버립니다.
        if [ -f "${LOG_FILE}.9" ]; then
            rm "${LOG_FILE}.9"
        fi

        # [2단계] 역순 반복 루프를 활용한 도미노 파일 밀기 (8번방부터 1번방까지)
        # - [문법] $(seq 시작 증감 끝): 연속된 숫자를 배열처럼 뿜어냅니다. 
        #   여기서는 "8부터 시작해서 -1씩 줄어들며 1이 될 때까지" 순회합니다. (8, 7, 6, ..., 1)
        # - [문법] for 변수 in 목록; do ... done: 리눅스 표준 반복문 문법입니다.
        for i in $(seq 8 -1 1); do
            # 순회 중인 번호의 파일(예: monitor.log.8)이 존재한다면
            if [ -f "${LOG_FILE}.$i" ]; then
                # 산술 확전을 통해 다음 번호 방 번호를 만듭니다. (8 + 1 = 9번방)
                next=$((i + 1))
                # mv(Move): 기존 8번 파일 이름을 9번 파일 이름으로 바꿔치기해서 뒤로 한 칸 밀어버립니다.
                mv "${LOG_FILE}.$i" "${LOG_FILE}.$next"
            fi
        done

        # [3단계] 방금 전까지 쓰던 꽉 찬 메인 로그 파일을 1번 백업방으로 이사보내기
        # - mv 명령어로 기존 monitor.log to monitor.log.1로 강제 대피시킵니다.
        # - && 기호: "앞 명령어가 100% 성공하면 뒤 명령어도 실행해라"라는 연쇄 조건문입니다.
        # - touch: 완전히 깨끗하게 비어있는 0바이트짜리 새 monitor.log 공책을 그 자리에 다시 개설합니다.
        mv "$LOG_FILE" "${LOG_FILE}.1" && touch "$LOG_FILE"
        
        # [4단계] 보안 무결성 재동기화
        # touch로 새로 태어난 공책은 권한이 풀려있으므로, 보안 지침에 맞게 다시 잠금장치를 걸어줍니다.
        sudo chown root:agent-core "$LOG_FILE"
        sudo chmod 660 "$LOG_FILE"
    fi
fi
# =========================================================================
# [스크립트의 끝] 이 대본은 크론탭(Crontab) 스케줄러에 의해 1분마다 무한 실행됩니다.
# =========================================================================
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
<img width="630" height="113" alt="04_directory" src="https://github.com/user-attachments/assets/6ff421a9-7a49-4eb4-89c1-107d083cb79c" />

---

### 📸 5) 앱 Boot Sequence 5단계 [OK] 및 “Agent READY” 확인 내역
> **체크리스트:** 파이썬 x86 바이너리의 내부 검증 통과 로그 및 READY 플래그 (수행: agent-dev)
```bash
$AGENT_HOME/agent-app-linux-x86
```
<img width="577" height="328" alt="05_app_boot" src="https://github.com/user-attachments/assets/4dfcf756-308a-447d-853a-0721c6fe9116" />

---

### 📸 6) `monitor.sh` 실행 결과(프로세스/포트/리소스) 내역
> **체크리스트:** 자원 수집 스크립트를 수동 1회 가동하여 정상 파싱 처리되는지 확인 (수행: agent-dev)
```bash
/home/agent-dev/agent-app/bin/monitor.sh
```
<img width="1032" height="155" alt="06_script_run" src="https://github.com/user-attachments/assets/ddd3d234-26d8-4f01-ac16-0247f045a2bc" />

---

### 📸 7) crontab 매분 정기 스케줄러 등록 및 상주 설정 내역
- **체크리스트**: 크론(cron) 시스템 장부에 모니터링 대본(`monitor.sh`)이 매분(`* * * * *`) 자발적으로 실행되도록 정상 등록되었는지 가동 스케줄 확인 (수행 계정: `agent-admin`)
- **실행 명령어**:
  ```bash
  crontab -l | grep -v '^#'
  ```
<img width="533" height="46" alt="07_cron_setting" src="https://github.com/user-attachments/assets/4aa2fbda-e21c-49b5-857e-0425f3402d99" />

---

### 📸 8) /var/log/agent-app/monitor.log 실시간 자동 누적 및 주기성 검증 내역
- **체크리스트**: 크론 스케줄러에 의해 인프라 관제 대본이 1분 주기로 자동 호출되며, 중앙 로그 저장소에 관제 데이터 라인이 끊김 없이 실시간 누적(로그 증가)되는지 추적 (수행 계정: `agent-admin`)
- **실행 명령어**:
  ```bash
  tail -f /var/log/agent-app/monitor.log
  ```
<img width="663" height="292" alt="08_monitor_log" src="https://github.com/user-attachments/assets/1c081da5-1829-44d9-a1a6-969ad8ac9c23" />

---
