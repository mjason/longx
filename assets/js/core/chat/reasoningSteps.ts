// A reasoning trace as titled steps, for the step-panel design of the
// reasoning element. OpenAI's summaries come with bold headings — each one
// opens a step and the paragraphs after it are the body. Raw thinking
// (DeepSeek and the like) has no headings: every paragraph is a step, its
// first sentence the title, the rest the body. Pure; DOM-free.
export type ReasoningStep = { title: string; body: string };

const HEADING = /^\*\*(.+?)\*\*:?\s*$/;
const TITLE_MAX = 60;

export function reasoningSteps(text: string): ReasoningStep[] {
  const paragraphs = text
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter((p) => p.length > 0);
  if (paragraphs.length === 0) return [];

  if (paragraphs.some((p) => HEADING.test(p))) {
    const steps: ReasoningStep[] = [];
    let current: ReasoningStep | null = null;
    for (const p of paragraphs) {
      const heading = HEADING.exec(p);
      if (heading) {
        current = { title: plain(heading[1]!), body: "" };
        steps.push(current);
      } else if (current) {
        current.body = current.body ? `${current.body}\n\n${plain(p)}` : plain(p);
      } else {
        // text before the first heading: a step of its own
        steps.push(sentenceStep(p));
      }
    }
    return steps;
  }
  return paragraphs.map(sentenceStep);
}

// the first sentence (or its first 60 chars) as the title, what follows as the body
function sentenceStep(paragraph: string): ReasoningStep {
  const p = plain(paragraph);
  // a sentence ends at CJK punctuation, or at .!? followed by a space — never
  // inside brackets ("(white/blank?)" is one sentence)
  const stop = /[。！？](?![)）\]」』"'])|[.!?]+(?=\s|$)/.exec(p);
  const end = stop ? stop.index + stop[0].length : -1;
  const first = end > 0 ? p.slice(0, end) : p;
  if (first.length <= TITLE_MAX && end > 0) return { title: first, body: p.slice(end).trim() };
  if (p.length <= TITLE_MAX) return { title: p, body: "" };
  return { title: `${p.slice(0, TITLE_MAX).trimEnd()}…`, body: p };
}

// inline markdown marks read as noise in a plain step
function plain(s: string): string {
  return s.replace(/\*\*|__|`/g, "").trim();
}
