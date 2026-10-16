# dot question · 공개 GitHub Actions 빌드

Mac/Windows 소스를 한 저장소에 두고, 필요한 OS만 GitHub 호스팅 러너에서 검사·패키징하는 구성입니다. 이 파일을 준비한 것만으로 저장소 생성, 소스 업로드 또는 Actions 실행이 이루어지지 않습니다.

## 실행 전

1. 공개 저장소의 main 브랜치에 게시하도록 준비된 소스입니다. 개인 자료·키·환경 파일·실제 사용자 로그는 추가하지 마세요. 공개된 소스는 누구나 열람할 수 있습니다.
2. 공개 저장소의 표준 GitHub 호스팅 러너 실행은 무료입니다. 저장 공간 등 모든 GitHub 기능의 무제한 무료 사용을 보장하지는 않습니다. 계정 과금 설정은 바꾸지 않습니다.
3. 이 폴더의 내용 전체를 승인된 저장소 루트에 넣습니다. 숨김 `.github` 폴더도 포함해야 합니다. 워크플로는 기본 브랜치에 있어야 수동 실행 메뉴가 나타납니다.
4. main의 앱·CI·워크플로 변경을 push하면 Mac과 Windows 작업이 시작됩니다. 수동 실행은 Actions → Build and test dot question → Run workflow에서 `macos`, `windows`, `both` 중 선택합니다. 기본은 `macos`입니다.
5. 성공한 실행의 Artifacts에서 해당 ZIP을 다운로드합니다. 보관 기간은 1일이므로 필요한 결과는 바로 보관하세요.

## 사용량 보호

- main 브랜치의 두 앱·ci 폴더·이 워크플로 파일 변경만 push 실행을 시작합니다. 수동 실행도 지원합니다. PR 및 스케줄 트리거는 없습니다.
- 표준 `macos-15` arm64 / `windows-2022` x64 러너만 사용합니다. 대형 러너는 사용하지 않습니다.
- OS별 작업 제한 20분. 같은 브랜치에서 새 실행을 시작하면 이전 실행을 취소합니다.
- 수동 실행 기본 선택은 Mac 하나입니다. push 또는 수동 `both`는 두 OS 작업을 실행합니다. 자동 재시도·무한 실행 루프는 없으며 실패 수정 커밋 또는 수동 실행으로 재검사합니다.
- 빌드 캐시를 별도로 업로드하지 않습니다. ZIP 산출물만 1일 보관합니다.
- 모델 다운로드, Ollama 설치/실행, 유료 API 호출, API 키 입력이 없습니다. GitHub/Python 패키지 다운로드와 산출물 전송에는 네트워크를 사용합니다.
- Copilot·Codex 등 AI 에이전트를 Actions에서 실행하지 않습니다.
- 빌드·테스트를 Actions로 옮겨도 이 대화의 AI 사용량까지 없어지는 것은 아닙니다.

GitHub는 공개 저장소의 표준 호스팅 러너 사용과 비공개 저장소의 무료 할당량을 다르게 취급합니다. 비공개 저장소의 할당량 초과와 산출물 저장은 과금 대상이 될 수 있으므로 실제 계정에서 확인해야 합니다.
출처: [GitHub Actions 과금](https://docs.github.com/en/billing/concepts/product-billing/github-actions), [호스팅 러너](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

## 검사와 결과물

### Mac

- 사전 설치된 Xcode 중 XCTest/Swift 사용 가능한 경로를 작업 환경 `DEVELOPER_DIR`로 선택합니다. 전역 `xcode-select` 변경이나 설치를 하지 않습니다.
- Python 구조 검사, XCTest 전체, release 빌드, Info.plist 및 ad-hoc 서명 검증을 수행합니다.
- 러너와 바이너리가 arm64인지 확인하고 `dot-question-macos-arm64.zip`을 만듭니다. Intel용이 아닙니다.
- Developer ID 서명·Apple 공증은 하지 않습니다. 다른 Mac에서 실행할 때 Gatekeeper의 차단/경고가 나타날 수 있습니다.

### Windows

- Python 3.12 x64 및 기존 requirements-build.txt를 설치합니다.
- Qt offscreen으로 unittest 전체를 실행합니다. 95개 미만 실행, 실패, skip을 CI 실패로 처리합니다. 테스트가 늘어나는 것은 허용합니다.
- PyInstaller onedir로 미서명 EXE를 패키징합니다. `DotQuestion.exe`만 떼어내지 말고 ZIP 내부 `DotQuestion` 폴더 전체를 유지하세요.
- OCR에 필요한 Tesseract 설치/언어 데이터는 이 패키지에 추가하지 않습니다. 실제 OCR 설정은 앱 README를 따르세요.

## 확인할 수 없는 범위

호스팅 러너는 사용자의 실제 키보드 LED, 로컬 화면/멀티 모니터, 메뉴 막대 사용성, 실제 전역 단축키 전달, 접근성·화면 기록 권한 흐름, 실제 로컬 모델 응답을 대신 검증하지 못합니다. 합성·모의 테스트 통과를 실제 기기 검증으로 해석하지 마세요. 현재 구성은 앱 빌드/테스트용이며 상시 앱 실행이나 AI 에이전트 호스팅용이 아닙니다.

## 액션 고정 및 재현성

공식 릴리스 페이지의 커밋 링크로 확인한 SHA에 고정했습니다.
- [checkout v4.4.0](https://github.com/actions/checkout/commit/11d5960a326750d5838078e36cf38b85af677262)
- [setup-python v7.0.0](https://github.com/actions/setup-python/commit/5fda3b95a4ea91299a34e894583c3862153e4b97)
- [upload-artifact v4.6.2](https://github.com/actions/upload-artifact/commit/ea165f8d65b6e75b540449e92b4886f43607fa02)

Python 패키지 버전은 원본 앱의 허용 범위를 유지하므로 완전한 lockfile 재현성은 아닙니다. 호스팅 러너의 Xcode와 OS 패치도 바뀔 수 있습니다. 설치된 도구 버전과 테스트 로그는 각 실행 로그에서 확인하세요.
