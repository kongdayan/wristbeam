# WristBeam

Garmin 시계를 Mac에 연결해 건강 및 운동 데이터를 확인하는 macOS 앱입니다. 데이터를 Mac에 보관하고 MCP와 API로 AI 도우미나 직접 만든 도구에서 사용할 수 있습니다.

[English](README.md) · [简体中文](README.cn.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

**[macOS용 다운로드](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-universal.zip)** · [업데이트 기록](CHANGELOG.md) · [문제 신고](https://github.com/kongdayan/wristbeam/issues)

macOS 13 이상이 필요합니다. 하나의 Universal 앱을 Apple Silicon과 Intel Mac에서 모두 사용합니다.

## 시작하기

1. ZIP 파일을 내려받아 압축을 풀고 **WristBeam.app**을 **응용 프로그램** 폴더로 옮깁니다.
2. **Devices → Connection**에서 안내에 따라 Bluetooth 접근을 허용하고 시계를 페어링합니다.
3. **Dashboard**에서 데이터를 확인합니다. 메뉴 막대와 플로팅 패널의 표시 항목은 **Settings**에서 선택합니다.

시계 데이터를 로컬에서만 사용한다면 로그인이 필요 없습니다. Garmin 클라우드 기록이나 파일 업로드를 사용하려면 **Devices → Device account**에서 로그인하고 **Sync records**에서 동기화 방식을 선택하세요.

[연결 및 설정 안내](docs/SETUP.md). 현재 배포본은 임시 서명이며 Apple 공증을 받지 않았습니다.

![데모 데이터를 사용한 대시보드, 메뉴 막대와 플로팅 패널](docs/images/showcase-hero.webp)

## 주요 기능

- **로컬 데이터 보관.** 시계의 운동·건강 FIT 원본 파일을 받아 Mac에 저장하고 내보냅니다. Garmin 클라우드 동기화는 선택 사항입니다.
- **AI와 자동화 연동.** 읽기 전용 MCP, HTTP/HTTPS API, Python SDK로 캐시된 건강·운동 데이터를 조회합니다. Webhook도 설정할 수 있으며, 연동 기능은 켜기 전까지 작동하지 않습니다.
- **일상 건강 확인.** 심박수, Body Battery, 스트레스, 걸음 수와 제공되는 추이를 대시보드·메뉴 막대·플로팅 패널에서 확인합니다.
- **운동 기록 확인.** 기록, 통계와 그래프를 열고, 데이터에 따라 JSON, TCX, GPX 또는 원본 파일로 내보냅니다.
- **시계 화면 관리.** Connect IQ에서 검색하고 Bluetooth로 설치한 뒤 지원되는 설정을 편집합니다. 현재 시계 화면 전환은 시계에서 제공하는 제어 기능에 따라 달라집니다.

## 호환 기기

**Instinct 2 Solar**는 실물 기기로 확인했습니다. 다른 Garmin 모델과 펌웨어는 개별 확인이 필요합니다. 표시되는 지표는 기기와 데이터 출처에 따라 다르며, 클라우드 전용 기록에는 계정 연결이 필요합니다.

[지원 기기](docs/DEVICES.md) · [지표 목록](docs/METRICS.md) · [검증 범위](VERIFICATION.md)

## 문서와 기여

- [설정 및 문제 해결](docs/SETUP.md)
- [Connect IQ 시계 화면](docs/CONNECTIQ.md)
- [MCP·API·Python SDK](docs/developer/API.md)
- [개발 및 기여](CONTRIBUTING.md) · [보안 문제](SECURITY.md)
- [추가 스크린샷](docs/SHOWCASE.md) · [업데이트 기록](CHANGELOG.md)

[MIT 라이선스](LICENSE)로 공개합니다. 기기 사용 결과, 수정 및 번역에 참여할 수 있습니다.
