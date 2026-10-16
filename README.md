# dot question

Mac/Windows OCR question assistant with local-model support.

한국어 설치·빌드·검증 안내: [README_KO.md](README_KO.md)

Public source and synthetic tests only. The current revision adds a bounded hosted-Mac live recording test; see Actions for its exact result. No API keys or personal documents are included.

The live test uses synthetic questions, a real global shortcut, OCR, and local Ollama inference. It stops if existing runner permissions are insufficient and never changes security settings. Keyboard hardware/LED support has been removed.
