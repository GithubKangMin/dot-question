// Self-contained: Chrome serializes this function into the isolated main-frame world.
// No page scripts, hidden answer keys, form values, network, or page mutations.
export function extractVisibleQuestions() {
  const MAX_CHARS = 30000, MAX_BYTES = 131072, MAX_QUESTIONS = 50;
  const rootsSelector = '[data-question], fieldset, [role="radiogroup"]';
  let visits = 0;
  function visible(el) {
    if (!el || el.nodeType !== 1) return false;
    for (let node = el; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (node.hidden || node.getAttribute('aria-hidden') === 'true' ||
          style.display === 'none' || style.visibility === 'hidden' ||
          style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
    }
    return el.getClientRects().length > 0;
  }
  function read(root, skip = new Set()) {
    let size = 0;
    function walk(node) {
      if (++visits > 100000) throw new Error('페이지가 너무 복잡합니다. 문제 영역을 줄이거나 OCR을 사용하세요.');
      if (node.nodeType === 3) {
        const text = node.textContent || '';
        size += text.length;
        if (size > MAX_CHARS) throw new Error('문제와 공통 지문은 합계 30,000자 이하여야 합니다.');
        return text;
      }
      if (node.nodeType !== 1 || skip.has(node) || !visible(node) ||
          /^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE|INPUT|TEXTAREA|SELECT|BUTTON|IFRAME|CANVAS|SVG)$/.test(node.tagName)) return '';
      const parts = [...node.childNodes].map(walk).join('');
      if (node.tagName === 'BR') return '\n';
      if (/^(TD|TH)$/.test(node.tagName)) return parts + '\t';
      return /^(P|DIV|SECTION|ARTICLE|LI|TR|H[1-6]|LEGEND)$/.test(node.tagName) ? parts + '\n' : parts;
    }
    return walk(root).replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
  }
  try {
    const roots = [...document.querySelectorAll(rootsSelector)].filter(visible).filter(el => {
      if (el.matches('[data-question]')) return ![...el.querySelectorAll('[data-question]')].some(visible);
      if (el.parentElement?.closest('[data-question]')) return false;
      if (el.matches('fieldset')) return ![...el.querySelectorAll('fieldset')].some(visible);
      return !el.parentElement?.closest('fieldset, [role="radiogroup"]');
    });
    if (roots.length > MAX_QUESTIONS) throw new Error('한 번에 50문제까지 가져올 수 있습니다.');
    const groups = [], groupMap = new Map();
    let total = 0;
    for (const root of roots) {
      if (root.parentElement?.closest('fieldset')) throw new Error('중첩된 문제 묶음은 공통 지문 연결을 확인해야 합니다. OCR을 사용하세요.');
      const radios = [...root.querySelectorAll('input[type="radio"]')].filter(visible);
      const customChoices = [...root.querySelectorAll('[data-choice], [role="radio"]')].filter(visible);
      const choices = [], excluded = new Set();
      if (radios.length && customChoices.length) throw new Error('보기 구조가 중복됩니다. OCR로 확인하세요.');
      if (new Set(radios.map(el => el.name)).size > 1) throw new Error('여러 문제의 보기가 섞여 있습니다. OCR로 확인하세요.');
      for (const radio of radios) {
        const labels = [...(radio.labels || [])].filter(visible);
        if (labels.length !== 1 || !root.contains(labels[0])) throw new Error('보기와 라벨의 연결을 확인할 수 없습니다.');
        excluded.add(labels[0]);
        const text = read(labels[0]);
        if (!text) throw new Error('읽을 수 없는 보기가 있습니다. OCR을 사용하세요.');
        choices.push({label: String(choices.length + 1), text});
      }
      for (const el of customChoices) {
        excluded.add(el);
        const text = read(el);
        if (!text) throw new Error('읽을 수 없는 보기가 있습니다.');
        choices.push({label: String(choices.length + 1), text});
      }
      if (choices.length > 5 || choices.length === 1) throw new Error('객관식은 2~5개 보기가 필요합니다.');
      if ([...root.querySelectorAll('img,canvas,svg,math,iframe')].some(visible)) {
        throw new Error('문제에 그림·수식·프레임이 있습니다. OCR로 전체 내용을 확인하세요.');
      }
      const prompt = root.querySelector('[data-question-text]');
      const text = prompt && visible(prompt) ? read(prompt) : read(root, excluded);
      if (!text) continue;
      const shortInput = root.querySelector('input:not([type]),input[type="text"],input[type="number"]');
      const longInput = root.querySelector('textarea');
      let type = choices.length ? 'multiple_choice' : longInput && visible(longInput) ? 'long_answer' :
        shortInput && visible(shortInput) ? 'short_answer' : root.getAttribute('data-question-type');
      const truth = new Set(['true', '참', 'o', '맞다']), falsity = new Set(['false', '거짓', 'x', '틀리다']);
      if (choices.length === 2 && choices.some(c => truth.has(c.text.trim().toLowerCase())) &&
          choices.some(c => falsity.has(c.text.trim().toLowerCase()))) type = 'true_false';
      if (!['multiple_choice', 'short_answer', 'true_false', 'long_answer'].includes(type)) {
        throw new Error('지원하지 않는 문제 유형이 섞여 있습니다. OCR 또는 사이트별 연결 확인이 필요합니다.');
      }
      if ((type === 'multiple_choice' && choices.length < 2) ||
          (type === 'true_false' && choices.length !== 2)) throw new Error('문제 유형과 보기 구조가 맞지 않습니다.');
      const contextNodes = new Set();
      const container = root.closest('[data-question-group]');
      if (container) {
        for (const el of container.querySelectorAll('[data-shared-context]')) {
          if (el.closest('[data-question-group]') === container && !el.closest(rootsSelector) && visible(el)) contextNodes.add(el);
        }
      }
      for (const id of (root.getAttribute('aria-describedby') || '').split(/\s+/).filter(Boolean)) {
        const el = document.getElementById(id);
        if (el && !el.closest(rootsSelector) && visible(el)) contextNodes.add(el);
      }
      for (const node of contextNodes) {
        if (node.matches('img,canvas,svg,math,iframe') || [...node.querySelectorAll('img,canvas,svg,math,iframe')].some(visible)) throw new Error('공통 지문에 그림·수식·프레임이 있습니다. OCR로 확인하세요.');
      }
      const context = [...contextNodes].map(el => read(el)).filter(Boolean).join('\n\n');
      // Only explicitly associated passages are reused; proximity is not evidence.
      const key = container || root;
      let group = groupMap.get(key);
      if (group && group.context !== context) group = undefined;
      if (!group) {
        group = {id: 'g' + (groups.length + 1), context, questions: []};
        groups.push(group); groupMap.set(key, group); total += context.length + group.id.length;
      }
      const question = {id: 'q' + (groups.reduce((n, g) => n + g.questions.length, 0) + 1), type, text, choices};
      total += question.id.length + text.length + choices.reduce((n, c) => n + c.label.length + c.text.length, 0);
      if (total > MAX_CHARS) throw new Error('문제와 공통 지문은 합계 30,000자 이하여야 합니다. 나눠서 가져오세요.');
      group.questions.push(question);
    }
    if (!groups.length) throw new Error('지원되는 문제 구조를 찾지 못했습니다. OCR을 사용하거나 사이트 샘플이 필요합니다.');
    const payload = {schema: 'dot-question/v1', groups};
    if (new TextEncoder().encode(JSON.stringify(payload)).length > MAX_BYTES) throw new Error('파일 크기 제한을 초과했습니다.');
    return {payload};
  } catch (error) {
    return {error: error.message || '문제를 읽지 못했습니다.'};
  }
}
