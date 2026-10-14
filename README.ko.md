<div align="center">
<img src="docs/images/app-icon.png" width="76" alt="WristBeam" />

# WristBeam

시계의 데이터를 Mac에서 조용히 확인하세요.

[![CI](https://github.com/kongdayan/wristbeam/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kongdayan/wristbeam/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/kongdayan/wristbeam)](https://github.com/kongdayan/wristbeam/releases/latest)
[![MIT](https://img.shields.io/badge/license-MIT-91d8b1)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-13%2B-1d2628?logo=apple)](https://github.com/kongdayan/wristbeam/releases/latest)

[简体中文](README.md) · [English](README.en.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Русский](README.ru.md)

</div>

![WristBeam](docs/images/showcase-hero.png)

**메뉴 막대 · 플로팅 패널 · 건강 대시보드**. 일반 Garmin Bluetooth 서비스로 데이터를 받고, 원본 FIT 파일을 Garmin Connect 중국 또는 글로벌 계정에 동기화합니다. Instinct 2 Solar와 중국 계정으로 실제 기기 검증을 마쳤습니다.

[다운로드](https://github.com/kongdayan/wristbeam/releases/latest) · [문제 및 기기 보고](https://github.com/kongdayan/wristbeam/issues) · [기여](CONTRIBUTING.md) · [변경 기록](CHANGELOG.md)

## 화면

![메뉴 막대와 클릭 후 패널](docs/images/showcase-menu.png)

![테마와 대시보드](docs/images/showcase-themes.png)

![표시 설정](docs/images/showcase-settings.png)

![Compact and Detailed floating panels](docs/images/showcase-floating.png)

실제 앱 UI에 분리된 데모 데이터를 표시합니다. [원본 화면과 제작 설명](docs/SHOWCASE.md).

## 기능

- 입체감 있는 작은 카드에 업데이트 시간을 표시합니다. 한 패널에서 배치와 기본 지표를 선택하고, 전체 보드·선택 카드·단일 값을 밝거나 어두운 프레임 이미지로 복사, 저장, 공유할 수 있습니다.
- 메뉴 막대, 패널, 대시보드를 개별 설정. 그룹 선택, 검색, 드래그 정렬, 글자 크기와 레이아웃 조절.
- 하루 곡선, 시간대별 막대, 날짜／시간 범위, 커서 값, 원본 기록. 누락 구간은 비워 둡니다.
- Garmin Bluetooth 페어링 안내, 원본 FIT 영구 대기열, 중복 제거 및 클라우드 동기화.
- 밝음／어두움／시스템 테마. 앱 UI는 중국어와 영어를 지원하며, 업데이트는 확인 후 진행합니다.

선택형 개발자 인터페이스: 읽기 전용 MCP, HTTP/HTTPS API, Bearer 키, 서명된 Webhook, Python SDK 및 stdio 브리지. [API 문서](docs/developer/API.md). 기본적으로 꺼져 있습니다.

## 기기 지원

현재 **Garmin** 시계를 지원하며, 실제 검증한 모델은 아래 표에 표시합니다. 다른 브랜드와 기기는 향후 확장 대상입니다.

| 시계 | 실시간 지표 | 원본 FIT＋중국 클라우드 | 태양광 기록 | 상태 |
| --- | --- | --- | --- | --- |
| Instinct 2 Solar | ✓ | ✓ | ✓ | 실제 기기 검증 |
| Instinct 2 / 2S / 2X | 미검증 | 미검증 | 모델에 따라 다름 | 보고 환영 |
| fēnix / epix / Forerunner | 미검증 | 미검증 | 모델에 따라 다름 | 보고 환영 |
| Venu / vívoactive 및 기타 | 미검증 | 미검증 | 모델에 따라 다름 | 보고 환영 |

펌웨어와 제공 서비스에 따라 달라집니다. 시리즈 전체의 호환성을 가정하지 않습니다. [지원 표와 보고 방법](docs/DEVICES.md).

## 수집 가능한 데이터

| 지표 | 출처 | 표시 |
| --- | --- | --- |
| 심박수·Body Battery·스트레스 | Garmin 알림＋클라우드 하루 기록 | 현재 값, 하루 곡선 |
| 걸음 수 | Bluetooth＋클라우드 | 일일 합계, 시간대별 증가량 |
| 호흡수·SpO₂ | 시계 측정 알림／클라우드 | 측정값, 하루 추이 |
| RR 간격 | Bluetooth | 밀리초. 야간 HRV 점수가 아닙니다 |
| 야간 HRV | 클라우드 수면 기록 | 야간·7일 평균, 상태, 기준 범위와 그래프. 누락 값은 비워 둡니다 |
| 시계 배터리 | Garmin Bluetooth | 기기 정보에 배터리 아이콘과 잔량 표시. 변경 알림 및 주기적 갱신 |
| 칼로리·층수·중고강도 운동 시간 | 시계／클라우드가 제공하는 필드 | 일일 통계, 일부 시간대별 데이터 |
| 안정 시 심박수·수면 시간·회복 통계 | 클라우드 일일 요약 | 요약 값, 관련 추이 |
| 태양광 강도 | 유효한 클라우드 분 단위 기록 | 0〜24시 곡선 |
| 햇빛／태양광 충전 시간 | 유효 입력 시간에서 추정 | 추정값으로 명시 |
| 활동 및 건강 FIT | 시계 원본 파일 | 로컬 보관, 클라우드 업로드 |

카탈로그에는 **건강 지표 60개와 기기 상태 필드 1개**가 있습니다. 유효 데이터를 받은 항목만 표시하며, 지원 여부는 기기에 따라 다릅니다. [전체 목록과 검증 상태](docs/METRICS.md).

## 설치

| Mac | 패키지 |
| --- | --- |
| Apple Silicon | [arm64](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-arm64.zip) |
| Intel | [x86_64](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-x86_64.zip) |
| 두 아키텍처 | [Universal](https://github.com/kongdayan/wristbeam/releases/latest/download/WristBeam-macOS-universal.zip) |

macOS 13 이상이 필요합니다. 압축을 풀고 쓰기 가능한 Applications 폴더에 옮기세요. 기기 → 연결에서 심박수 브로드캐스트를 끈 시계를 준비하고 연결 버튼을 눌러 Bluetooth를 허용합니다. 기기 계정에서 중국／글로벌을 선택해 Garmin 공식 페이지에서 로그인한 후 동기화 기록에서 수동／자동 업로드를 선택하세요. 시작 시 자동 연결은 기본적으로 꺼져 있으며 페어링 후 켤 수 있습니다.

현재 임시 서명이며 Apple 공증은 없습니다. 실제 글로벌 계정 업로드와 다른 펌웨어는 미검증입니다. 앱 계층 암호화, native MLR / CoreTransfer와 데스크톱 위젯은 미지원입니다. Mac이 잠들면 즉시 동기화할 수 없습니다. [검증 범위](VERIFICATION.md).

## 기여와 공유

PR, 번역, 기기 결과와 아이디어를 환영합니다. **[MIT](LICENSE)** 라이선스를 유지하면 사용·수정·재배포할 수 있습니다. Garmin 공식과 무관한 독립 프로젝트입니다.

[개발 및 PR 안내](CONTRIBUTING.md) · [보안 보고](SECURITY.md) · [자동 릴리스](docs/RELEASING.md)
