# dot question

Mac/Windows OCR question assistant with local-model support.

한국어 설치·빌드 안내: [README_KO.md](README_KO.md)

## Verified actual Mac recording · 2026-10-16

[Successful Mac and Windows run 38857708247](https://github.com/GithubKangMin/dot-question/actions/runs/38857708247) tested source commit `7aebc55e5039736032d1d8adb43d1622b7c94a1f`.

- 76 native Mac tests, 104 Windows tests, release builds and packaging passed.
- One unedited 232.470-second desktop recording: three separate synthetic questions, three real OS global shortcuts, Vision OCR, local Ollama qwen2.5:7b, strictly validated answers 2 → 3 → 5.
- The app-owned five-bar menu icon stays visible at fixed width: zero filled bars while idle/pending, then the answer until the next command. Each answer visibly held for at least ten seconds. The main app window stayed hidden.
- All 307 decoded frames were checked against the actual question screenshots and fixed bar positions. No compositing, inserted answer frames, paid API, cloud model, security/TCC changes, user computer or personal data.
- This demonstrates three examples, not general accuracy. Numeric-only choices can lose spacing during OCR; their separate conservative geometry regression is not covered by this successful word-choice video.

See [evidence, timing, earlier failures and limitations](CI_VALIDATION_KO.md). Mac is ad-hoc signed, not Developer ID signed/notarized; Windows is unsigned. Actions artifacts expire after one day. Later commits must be assessed separately from the recorded source above.
