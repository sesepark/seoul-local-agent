# 서울대 로컬 에이전트

Apple Silicon Mac에서 수동으로만 실행하는 로컬 개인 자동화 도구입니다. 메뉴바 앱은 로그인·화면 열기·잠자기 해제에서 수집이나 LLM 추론을 시작하지 않습니다.

## 제공 기능

- 전사 모델을 설정에서 독립적으로 선택할 수 있습니다: `Qwen3-ASR 0.6B 8-bit`(초고속), `0.6B`(균형), `1.7B`(정밀), `1.7B + 0.6B 초안`(실험). 8-bit 모델은 기존 0.6B를 보존한 채 `~/.cache/seoul-local-agent/Qwen3-ASR-0.6B-8bit`에 별도로 저장됩니다.
- 화자 구분은 ASR과 별도 단계입니다. `사용 안 함`, `pyannote Community-1`(권장), `Legacy 3.1`(호환용)을 선택할 수 있습니다. Community-1/3.1은 해당 Hugging Face 모델 이용 승인이 필요합니다.

- `인박스 정리 시작`: Gmail 두 계정, Slack, macOS 메시지 앱(iMessage·SMS·RCS)의 새 항목을 **읽기 전용**으로 수집합니다. Gmail 스레드 본문, Slack DM·채널 멘션, 메시지 앱의 일반 텍스트·`attributedBody`를 사실 카드로 추출한 뒤 사건 단위로 합치고 `오늘 꼭 할 일`, `확인해야 할 것`, `기타`로 편집합니다. Notion에는 추천 행동을 쓰지 않고 발신자·요청·맥락·명시된 마감과 결과를 더 자세히 요약합니다.
- `중지`: 작업을 취소하고 Ollama 모델을 언로드합니다.
- 로컬 Codex: 원하는 Terminal과 작업 폴더에서 `local-llm-codex`를 실행하면 Codex OSS/Ollama 읽기 전용 세션이 시작되며, 종료·중단 시 모델을 즉시 언로드합니다.
- `최근 결과 보기`: 마지막 생성 Notion 페이지를 엽니다.
- `전역 받아쓰기`: 어느 앱에서든 단축키(기본 `⌃⌥⌘D`)를 누르면 녹음이 시작되고, 다시 누르면 이 Mac에서 바로 변환해 클립보드에 넣습니다. `설정 → 전역 받아쓰기`에서 단축키·모델·언어를 바꾸고, 손쉬운 사용 권한을 허용하면 커서 위치에 자동으로 붙여넣습니다. 녹음 파일은 변환 직후 삭제하며 보관함에 남기지 않습니다.
- `영상에서 가져오기`: 녹음·전사 화면에 강의 영상 주소를 붙여넣으면 `yt-dlp`로 오디오만 내려받아 16 kHz 모노로 변환한 뒤 전사 대기열에 넣습니다. 영상 파일을 그대로 드롭해도 `ffmpeg`로 오디오만 추출합니다. `brew install yt-dlp ffmpeg`가 필요합니다.
- `문서 인식`: 두 가지 방식을 고를 수 있습니다. `빠름`은 macOS 내장 문자 인식(Vision)으로 다운로드 없이 즉시 글자를 뽑고, `정밀`은 MinerU 문서 모델로 수식을 LaTeX, 표를 표 그대로 살려 Markdown을 만듭니다. 수식이 있는 슬라이드나 문제지는 `빠름`으로는 깨지므로 `정밀`을 쓰세요. 어느 쪽이든 이미지가 이 Mac을 벗어나지 않습니다. 강의 슬라이드 사진, 스캔한 유인물 PDF, 화면의 일부를 처리합니다. 별도 모델을 내려받지 않고 이미지가 기기를 벗어나지 않습니다. 텍스트가 들어 있는 PDF는 인식 없이 내장 텍스트를 그대로 읽고, 스캔본만 쪽 단위로 인식합니다. 결과는 복사·저장하거나 같은 로컬 모델로 정리할 수 있습니다.
- `누끼 따기`: 사진을 드롭하면 배경을 지운 투명 PNG를 돌려줍니다. 기본은 오픈소스 최고 품질인 BiRefNet_HR-matting(MIT, 2048×2048)이며 머리카락·털·반투명까지 소프트 알파로 뽑습니다. 설정에서 1024 균형 모델이나 다운로드가 필요 없는 macOS 내장 피사체 분리로 바꿀 수 있습니다. 여러 장을 한 번에 드롭하면 순서대로 처리하고 폴더로 일괄 저장합니다. 배경은 투명·흰색·검정·직접 선택 중에 고를 수 있으며, 배경색을 바꿔도 다시 계산하지 않습니다. 사진은 이 Mac을 벗어나지 않습니다.
- `녹음 전사`: 메뉴바 창 하단에 회의·강의 녹음 파일을 드롭하면 Qwen3-ASR-1.7B를 Apple Silicon MLX로 필요할 때만 실행해 한국어 전사·타임스탬프·화자 구분 결과를 표시하고 클립보드로 복사합니다. 결과 임시 파일과 모델 프로세스는 작업 종료 후 정리됩니다.

## 보안 경계

- Gmail은 `gog --readonly` 두 계정만 사용하며, Slack은 Keychain의 읽기 토큰만 읽습니다. 원본의 전송·수정·삭제·반응은 구현되어 있지 않습니다.
- 메시지 본문은 신뢰하지 않는 데이터로만 LLM에 제공합니다. 시스템 프롬프트·도구 실행·브라우저 실행 지시로 해석하지 않습니다.
- Notion 쓰기는 `3b8b3e65-af46-8037-aa2f-e625ef9f5662`의 직접 하위 페이지로만 제한하며, 코드에서 parent ID를 다시 검사합니다. 다른 페이지 쓰기·이동·삭제 기능은 없습니다.
- 토큰은 저장소에 없고 기존 Gog/Notion 안전 저장소 및 macOS Keychain을 사용합니다. 로컬 상태 파일은 `~/Library/Application Support/SeoulLocalAgent/state.json`에 권한 `0600`으로 저장되며 원문 본문을 저장하지 않습니다.

## 개발과 검증

```zsh
scripts/run-tests.sh
```

`swift test`를 직접 실행하면 `xcode-select`가 Command Line Tools를 가리킬 때 테스트를 **하나도 실행하지 않고** 성공으로 끝납니다(그 툴체인에는 `xctest` 러너가 없습니다). 위 스크립트는 설치된 Xcode 툴체인을 지정한 뒤 실행하므로 항상 실제로 테스트가 돌아갑니다.

## 처음 실행

```zsh
cd <이 저장소를 클론한 경로>
chmod 700 scripts/local-codex scripts/build-app-bundle.sh scripts/setup-matting-env.sh scripts/setup-docparse-env.sh
scripts/setup-matting-env.sh    # 누끼 기능을 쓸 때만 필요합니다
scripts/setup-docparse-env.sh   # 문서 인식 `정밀` 모드를 쓸 때만 필요합니다
scripts/build-app-bundle.sh
open dist/SeoulLocalAgent.app
```

첫 실행 뒤 메뉴바의 졸업모 아이콘을 눌러 실행합니다. 이 앱은 로그인 항목이나 launchd 항목을 만들지 않습니다.

### Gmail 계정 설정

인박스 정리에서 읽을 Gmail 계정은 소스에 넣지 않고 기기별 설정 파일로 지정합니다.
메일 주소는 개인정보이므로 저장소에 커밋하지 않습니다.

```zsh
mkdir -p ~/Library/"Application Support"/SeoulLocalAgent
cat > ~/Library/"Application Support"/SeoulLocalAgent/gmail-accounts.json <<'JSON'
[
  {"address": "you@example.com",  "mailboxIndex": 0},
  {"address": "you@gmail.com",    "mailboxIndex": 1}
]
JSON
chmod 600 ~/Library/"Application Support"/SeoulLocalAgent/gmail-accounts.json
```

`mailboxIndex`는 브라우저에서 그 계정이 갖는 `/mail/u/<n>/` 번호입니다. 스레드 링크를 이
번호로 만들기 때문에, 로그인한 브라우저의 순서와 다르면 링크가 엉뚱한 메일함으로 열립니다.

파일이 없으면 Gmail만 수집에서 빠지고 Slack·메시지 앱 수집은 그대로 동작합니다.
접근은 어느 쪽이든 `gog --readonly` 읽기 전용입니다.

## 권한 확인

Notion 통합은 이 부모 페이지에만 공유되어 있어야 합니다. 부모를 찾지 못하거나 권한이 없으면 페이지를 만들지 않고 오류만 표시합니다.

```zsh
gog auth list
ntn doctor
openclaw channels status --probe
```

Slack 토큰은 기존 Keychain 항목 `com.openclaw.slack.bot-token/openclaw-local`을 읽습니다. OpenClaw Gateway는 이 앱에 필요하지 않으며, 자동 시작하지 않도록 별도 해제할 수 있습니다.

## 모델/로그/제거

- 모델 설정: 자동 정리는 기본 모델에서 16K context·temperature 0.1로 실행합니다. `분석 품질`이 `정밀`이면 사실 추출 6개·한국어 편집 4개 배치, `균형`이면 3개·2개의 짧은 배치를 사용합니다. 로컬 27B 모델 실측으로 항목당 약 12초가 들고 한국어 편집이 한 번 더 돌기 때문에, 100건이면 30~50분 정도 걸립니다. 수집 범위를 `마지막 성공 이후`로 두면 매번 새 항목만 처리합니다. `local-llm-codex`는 별도 `qwen36-fable-27b-mtp-q4-codex` 모델과 Codex 32K profile을 사용합니다. 둘 다 작업 종료 시 즉시 언로드합니다.
- 문서 인식 `정밀` 모드: `scripts/setup-docparse-env.sh`가 `.venv-docparse`를 만들고 MinerU2.5-Pro 1.2B 가중치(약 2.2GB)를 `~/.cache/seoul-local-agent/hf`에 내려받습니다. M2 Max 실측으로 15쪽 논문이 약 63초(쪽당 4초 안팎)입니다. MinerU는 Apple Silicon에서 사용 가능한 메모리를 1GB로 잘못 읽어 한 번에 한 쪽만 처리하므로, 앱이 물리 메모리의 1/4을 `MINERU_VIRTUAL_VRAM_SIZE`로 알려 줍니다. 같은 문서 기준 288초에서 30초로 줄어드는 차이라 이 설정이 없으면 실용적이지 않습니다. Hugging Face의 Xet 전송 백엔드가 중간에 멈추는 문제가 있어 `HF_HUB_DISABLE_XET=1`로 일반 HTTP 경로를 씁니다. MinerU는 실행할 때마다 자체 로컬 API 서비스를 손자 프로세스로 띄우므로, 중단·실패·앱 종료 어느 경우에도 프로세스 트리 전체를 정리합니다.
- 누끼 모델: `scripts/setup-matting-env.sh`가 전사용 환경과 분리된 `.venv-matting`을 만듭니다(torch·torchvision·transformers·timm·einops·kornia). 가중치는 처음 누끼를 딸 때 `~/.cache/seoul-local-agent/hf`에 약 900MB 내려받습니다. M2 Max 실측으로 2048 모델은 첫 장 5~6초, 이어지는 장은 2~3초입니다. 추론 프로세스는 사진 사이에 상주하지만 마지막 사진에서 5분이 지나면 스스로 종료하고, 앱을 끄면(강제 종료 포함) 함께 사라집니다. 파이프가 닫히거나 앱 프로세스가 없어지면 즉시 빠져나오도록 되어 있어 뒤에 남는 프로세스가 없습니다. 다음 실행에서 남은 러너를 발견하면 시작할 때 정리합니다.
- 이월 규칙: 기본 수집 범위는 `마지막 성공 이후`이며, 매 실행은 새 항목만 모읍니다. 이전 브리핑의 항목 중 **Notion에서 아직 체크하지 않았고 마감이 지나지 않은 할 일**과 **아직 시작하지 않은 캘린더 일정**은 오늘 페이지로 이월됩니다. 이월된 항목은 내용이 그대로면 모델을 다시 거치지 않으므로 실행 시간이 크게 줄어듭니다. 마감이 지난 미완료 항목은 이월하지 않고 `기타` 섹션에 개수만 남깁니다. 마감이 없는 할 일은 체크할 때까지 계속 이월됩니다.
- 브리핑 설정: 앱의 `설정`에서 수집 범위(기본 `마지막 성공 이후`), 분석 품질, Notion에 표시할 TODO/확인 항목 개수, 채널 멘션용 Slack Member ID를 관리합니다. 자동 브리핑 화면에는 현재 설정과 실행 중 예상 남은 시간이 표시됩니다.
- 개인화: `설정 → 분류 기준`에서 사용자 지침, 항상 중요 패턴, 항상 무시 패턴을 모두 조회·수정하고 기본값으로 복원할 수 있습니다. 한 줄에 한 패턴을 입력하며 중요 규칙이 무시 규칙보다 우선합니다. 숨은 발신자 차단 목록은 사용하지 않습니다.
- Codex profile: `~/.codex/local-coding.config.toml`은 CookieRunHub의 Python/Next.js/mobile/Docker 구조를 우선 확인하고, 기본적으로 분석·제안만 하도록 추가 지시를 제공합니다. 일반 OpenAI Codex 설정에는 영향을 주지 않습니다.
- 수집 한계: Gmail은 계정당 최근 400스레드까지 검색합니다. 상한에 닿으면 누락 가능성을 브리핑의 `실패한 소스 또는 권한 오류` 항목과 진행 화면에 표시합니다. Slack은 rate limit(429)을 기다렸다 재시도하고, 읽지 못한 채널이 있으면 나머지를 살린 뒤 그 사실을 함께 보고합니다. 부분적으로만 성공한 소스는 체크포인트를 전진시키지 않습니다.
- 로그: 앱은 토큰이나 메시지 본문을 로그에 남기지 않습니다. 실행 오류는 메뉴바와 위 state 파일의 `lastError`에만 간단히 저장됩니다.
- 권한: 받아쓰기는 마이크 권한, 자동 붙여넣기는 손쉬운 사용 권한, 화면 영역 캡처는 화면 기록 권한이 필요합니다. 셋 다 해당 기능을 처음 쓸 때만 요청하며 허용하지 않아도 나머지 기능은 그대로 동작합니다.
- 제거: 앱을 종료한 뒤 `dist/SeoulLocalAgent.app` 및 `~/Library/Application Support/SeoulLocalAgent`를 삭제하면 됩니다. Ollama, Gog, Notion, OpenClaw 설정이나 다른 모델은 건드리지 않습니다.
