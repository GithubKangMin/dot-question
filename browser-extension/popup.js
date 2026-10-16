import {extractVisibleQuestions} from './extractor.js';
const capture = document.getElementById('capture');
const download = document.getElementById('download');
const status = document.getElementById('status');
const preview = document.getElementById('preview');
let payload = null;
capture.addEventListener('click', async () => {
  payload = null; download.disabled = true; capture.disabled = true; preview.textContent = '';
  status.textContent = '현재 탭을 읽는 중…';
  try {
    const [tab] = await chrome.tabs.query({active: true, currentWindow: true});
    if (!tab?.id) throw new Error('현재 탭을 찾을 수 없습니다.');
    const results = await chrome.scripting.executeScript({target: {tabId: tab.id}, func: extractVisibleQuestions});
    const result = results[0]?.result;
    if (!result?.payload) throw new Error(result?.error || '이 페이지에서는 읽을 수 없습니다.');
    payload = result.payload;
    preview.textContent = payload.groups.map(g => ['공통 지문\n' + (g.context || '(연결된 지문 없음)'),
      ...g.questions.map(q => `${q.id} · ${q.type}\n${q.text}\n${q.choices.map(c => `${c.label}. ${c.text}`).join('\n')}`)].join('\n\n')).join('\n\n────────\n\n');
    status.textContent = '읽기 완료. 지문과 문제 연결을 검토한 뒤 저장하세요.'; download.disabled = false;
  } catch (error) { status.textContent = error.message || '읽기를 완료하지 못했습니다. OCR을 사용하세요.'; }
  finally { capture.disabled = false; }
});
download.addEventListener('click', () => {
  if (!payload) return;
  const url = URL.createObjectURL(new Blob([JSON.stringify(payload)], {type: 'application/json'}));
  const link = document.createElement('a'); link.href = url; link.download = 'dot-question.json';
  link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  status.textContent = '저장을 요청했습니다. 파일을 앱에서 직접 가져오세요.';
});
