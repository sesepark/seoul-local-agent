# 서울대 로컬 에이전트

Apple Silicon Mac에서 **전부 기기 안에서** 도는 개인 자동화 메뉴바 앱입니다. 받은 메일·메시지와
학교 공지를 읽어 오늘 할 일로 정리하고, 녹음을 전사하고, 문서를 인식하고, 사진·영상을 다듬습니다.
데이터가 이 Mac을 벗어나지 않는 것과, 사용자가 누르지 않으면 아무것도 시작하지 않는 것을
설계 전제로 두었습니다.

> *A menu-bar personal-automation app for Apple Silicon that runs entirely on-device. It reads mail,
> chat and university notice boards read-only, edits them into a daily briefing kept inside the app,
> and turns items into Calendar events. It also transcribes, parses documents and processes media.
> Nothing leaves the machine and nothing starts without a click. Documentation is in Korean.*

---

## 무엇을 하는가

| 기능 | 내용 |
|---|---|
| **인박스 정리** | Gmail 2계정 · Slack · 메시지 앱 · 캘린더 · 학교 공지 게시판을 **읽기 전용**으로 모아 `오늘 꼭 할 일` / `확인해야 할 것` / `기타`로 편집합니다 |
| **브리핑 보관함** | 정리 결과가 날짜별로 앱 안에 쌓입니다. 체크·메모·검색을 하고, 항목을 Mac 캘린더나 미리 알림으로 넘깁니다 |
| **녹음·전사** | Qwen3-ASR(0.6B~1.7B, MLX)로 한국어 전사·타임스탬프, pyannote 화자 구분 |
| **전역 받아쓰기** | 어느 앱에서든 단축키로 녹음 → 기기 내 변환 → 클립보드·커서 위치 삽입 |
| **문서 인식** | `빠름`은 macOS Vision, `정밀`은 MinerU로 수식을 LaTeX·표를 표로 살린 Markdown |
| **누끼 따기** | BiRefNet_HR-matting으로 투명 PNG, 자르기·뒤집기 편집 |
| **용량 줄이기** | 사진·PDF·영상을 macOS 내장 인코더로 축소, 목표 용량 지정 가능 |
| **로컬 Codex** | Codex OSS/Ollama 읽기 전용 세션, 종료 시 모델 즉시 언로드 |

## 구성

```
Sources/SeoulLocalAgent/
  SeoulLocalAgentApp.swift    앱 진입점, 화면 전환, AutomationController(전 화면 공용 상태)
  Models.swift                수집 항목·분류 결과·화면 목록 같은 공용 타입
  Services.swift              Gmail·Slack·메시지·캘린더 수집과 로컬 모델 호출
  BriefingService.swift       수집 → 분류 → 이월 → 저장 파이프라인
  BriefingArchive*.swift      브리핑 보관함: 저장 형식, 화면, 체크·메모·캘린더 연결
  CalendarWriting.swift       전용 캘린더·미리 알림 쓰기, 중복 방지
  DeadlineParsing.swift       한국어 마감 표기를 날짜로
  TriagePreparation.swift     분류 전 정제, 표시 문장, 이월 규칙
  BatchTool.swift / ToolKit.swift   파일 도구 공통 뼈대(큐·드롭·툴바·결과 카드)
  *Compression / Upscaling / ScanCorrection / PDFToolbox / FileConversion 등  도구별 구현
scripts/
  build-app-bundle.sh         .app 번들 생성과 서명
  run-tests.sh                테스트 진입점 (swift test를 직접 쓰면 안 됨)
  setup-*.sh                  기능별 Python 가상환경
  *_runner.py                 전사·누끼·미디어 상주 러너
  eval/                       분류 품질 측정용 합성 데이터와 스크립트
docs/사용_안내.md              기능별 전체 설명과 운용 절차
```

## 설계에서 신경 쓴 부분

- **보안 경계를 관례가 아니라 코드로 강제합니다.** Gmail은 `gog --readonly` 두 계정만, Slack은
  Keychain의 읽기 토큰만 씁니다. 전송·수정·삭제·반응은 **구현되어 있지 않습니다.** 캘린더와
  미리 알림은 쓰기도 하지만 `서울대 로컬 에이전트`라는 전용 캘린더·목록에만 쓰고, 지우기 전에
  그 캘린더가 앱이 만든 것인지 다시 확인합니다. 원래 쓰던 일정은 만들지도 고치지도 지우지도
  않습니다. Notion 쓰기는 기본적으로 꺼져 있고 `Notion으로 내보내기`를 눌렀을 때만 일어나며,
  그때도 지정한 부모 페이지의 직접 하위로만 가능하고 코드에서 parent ID를 다시 검사합니다.
  권한을 좁게 설정하는 것과 기능을 아예 만들지 않는 것은 사고가 났을 때 결과가 다릅니다.
- **메시지 본문을 지시로 해석하지 않습니다.** 수집한 본문은 신뢰하지 않는 데이터로만 모델에
  넘깁니다. 남이 보낸 메일이 이 에이전트의 시스템 프롬프트나 도구 실행으로 승격될 수 있으면,
  받은편지함이 곧 공격 표면이 되기 때문입니다.
- **자식 프로세스가 뒤에 남지 않게 합니다.** 누끼·미디어 러너는 stdin EOF · 부모 PID 소멸 ·
  5분 유휴 중 먼저 오는 조건에 스스로 종료하고, 앱을 강제 종료해도 함께 사라집니다. MinerU는
  자체 API 서비스를 손자 프로세스로 띄우므로 중단·실패·종료 어느 경우에도 프로세스 트리 전체를
  정리하고, 다음 실행에서 남은 러너를 발견하면 시작할 때 치웁니다.
- **분류와 한국어 문장을 한 번의 요청에서 만듭니다.** 요약을 2차 호출로 다시 다듬지 않기 때문에
  문장이 원문을 보면서 쓰이고, 항목당 실측 3.6~6.0초로 100건이 10분 안쪽에 끝납니다.
  (측정 방법은 `scripts/eval/README.md`)
- **결과가 앱 안에 남습니다.** 브리핑은 원래 Notion 페이지에 쓰였고, 다음 날 무엇이 남았는지도
  그 페이지의 체크박스를 되읽어서 정했습니다. 즉 인터넷이 없으면 앱이 자기가 만든 결과조차
  볼 수 없었고, 제목이 조금만 바뀌어도 이월 추적이 끊겼습니다. 지금은 `브리핑 보관함` 화면이
  원본이고, 완료 여부는 항목의 안정 ID로 `briefing-archive.json`(권한 0600)에 남습니다.
  네트워크 왕복이 사라졌고, 화면에 다 싣지 못해 이월되지 못하던 항목도 없어졌습니다.
- **마감 문장을 날짜로 읽되, 애매하면 묻습니다.** `9월 15일까지` · `내일 오후 6시` ·
  `다음 주 금요일` 같은 표기를 직접 해석해 캘린더에 넣습니다. `가급적 빨리`처럼 날짜가 아닌
  말은 아예 해석하지 않고, 시각만 적힌 경우처럼 확신이 없으면 날짜 선택기를 채워서 확인받습니다.
  남의 캘린더에 조용히 들어간 틀린 날짜는 날짜가 없는 것보다 나쁘기 때문입니다.
- **첫 공지 수집은 기준선만 저장하고 아무것도 보고하지 않습니다.** 게시판 앞면 전체가 새 글로
  잡히면 그날 브리핑이 묻히기 때문입니다. 새 글 판정도 날짜가 아니라 **글 주소**로 합니다.
  게시판마다 날짜 형식이 제각각이라 주소를 기억하는 편이 안정적입니다.
- **남은 시간을 개수가 아니라 예상 소요 시간으로 셉니다.** 한 묶음에 2MP 스크린샷과 48MP 사진과
  10분짜리 영상이 섞여 들어오므로 개수로 세면 몇 배씩 틀립니다.
- **플랫폼 오작동을 우회합니다.** MinerU는 Apple Silicon에서 가용 메모리를 1GB로 잘못 읽어 한 번에
  한 쪽만 처리합니다. 앱이 물리 메모리의 1/4을 `MINERU_VIRTUAL_VRAM_SIZE`로 알려 주면 같은 문서가
  288초에서 30초로 줄어듭니다. 이 설정이 없으면 기능이 성립하지 않습니다.

## 실행

```zsh
chmod 700 scripts/local-codex scripts/build-app-bundle.sh scripts/setup-*.sh
scripts/build-app-bundle.sh
open dist/SeoulLocalAgent.app
```

선택 기능(누끼·문서 인식 `정밀`·소리 다듬기·영상 압축)은 각각 별도 셋업 스크립트와 brew 패키지가
필요합니다. 전체 절차와 Gmail 계정 설정은 [docs/사용_안내.md](docs/사용_안내.md)에 있습니다.

테스트는 반드시 `scripts/run-tests.sh`로 돌립니다. `swift test`를 직접 실행하면 `xcode-select`가
Command Line Tools를 가리킬 때 **테스트를 하나도 실행하지 않고 성공으로 끝납니다.**

## 문서

| 문서 | 내용 |
|---|---|
| [docs/사용_안내.md](docs/사용_안내.md) | 기능별 전체 설명, 화면 구성, 웹 공지 수집, 처음 실행, 권한, 모델·로그·제거 |
| `scripts/eval/README.md` | 분류 파이프라인 속도·품질 측정 방법과 결과 |

## 한계와 주의

- **macOS 26 이상, Apple Silicon 전용입니다.** Liquid Glass를 그대로 쓰려고 배포 타깃을 26으로
  두었고, 모델은 MLX 빌드라 Intel Mac에서는 동작하지 않습니다.
- Notion 연동은 남아 있지만 기본값이 꺼짐입니다. 보관함 툴바의 `Notion으로 내보내기`를 눌렀을
  때만 그날 브리핑이 올라갑니다.
- 개인 설정(Gmail 주소, Notion 부모 페이지, Slack 토큰)은 저장소에 없습니다. 기기별 설정 파일과
  Keychain으로만 다루며, 넣는 방법만 문서에 적혀 있습니다.
- Gmail은 계정당 최근 400스레드까지만 검색합니다. 상한에 닿으면 누락 가능성을 브리핑에 표시합니다.
- 학교 공지 게시판은 개편되면 조용히 0건이 됩니다. `--web-notices-check`로 어느 게시판이 살아
  있는지 확인할 수 있습니다. 사범대·생활과학대·의대·치의학대학원 네 곳은 목록이 자바스크립트로만
  그려지거나 링크가 `javascript:` 호출이라 읽을 수 없어 꺼 두었습니다.
- **기기별 절대 경로가 코드에 박혀 있습니다.** Python 러너와 셋업 스크립트가
  `/Users/sehwan/Projects/local_llm/...`을 그대로 참조하므로, 다른 경로에 두면 전사·누끼·
  소리 다듬기·문서 인식 `정밀`이 동작하지 않습니다. 본인 Mac 한 대에서 쓰려고 만든 도구라
  아직 정리하지 않았습니다.
- 자동으로 시작하는 것이 없습니다. 로그인 항목도 launchd 항목도 만들지 않으므로, 브리핑은 직접
  눌러야 돌아갑니다. 이건 제약이 아니라 의도입니다.
