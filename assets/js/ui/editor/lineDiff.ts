// The diff the merge view runs, the way VS Code's diff editor works: lines
// first, then characters only inside the stretches that changed.
//
// @codemirror/merge diffs the two texts character by character, and the
// merge view caps that search (`scanLimit` 500): past 500 × 64 characters
// of changed region it gives up and answers one change for all of it — a
// uv.lock with a block added at the top and hashes changed below showed as
// the whole file deleted on the left and inserted on the right. Here each
// line becomes one character, the package's own `diff` finds the unchanged
// lines exactly (a few thousand "characters", no cap needed), and only the
// gaps between them are compared character by character.
import { Change, diff, presentableDiff } from "@codemirror/merge";

// a gap bigger than this is marked whole: its characters are not compared
// (unless its lines pair up, below)
const REFINE_MAX_CHARS = 20_000;
// a gap whose characters mostly differ is marked whole too — a scatter of
// matching letters between unrelated lines reads worse than one block
const REFINE_MAX_CHANGED = 0.6;
// line ids as UTF-16 code units, skipping the surrogate range
const SURROGATES = 0xd800;
const SURROGATE_SPAN = 0x800;
const MAX_IDS = 0x10000 - SURROGATE_SPAN;

type Lines = { starts: number[]; code: string };

// each line (with its newline) as one character; `starts` are the lines'
// offsets in the text, plus the end
function encode(text: string, ids: Map<string, number>): Lines | null {
  const starts: number[] = [];
  const units: number[] = [];
  let pos = 0;
  while (pos < text.length) {
    const nl = text.indexOf("\n", pos);
    const end = nl < 0 ? text.length : nl + 1;
    const line = text.slice(pos, end);
    let id = ids.get(line);
    if (id === undefined) {
      id = ids.size;
      if (id >= MAX_IDS) return null;
      ids.set(line, id);
    }
    starts.push(pos);
    units.push(id < SURROGATES ? id : id + SURROGATE_SPAN);
    pos = end;
  }
  starts.push(text.length);
  let code = "";
  for (let i = 0; i < units.length; i += 4096) code += String.fromCharCode(...units.slice(i, i + 4096));
  return { starts, code };
}

// a change that starts where the last one ended joins it
function push(out: Change[], c: Change) {
  const last = out[out.length - 1];
  if (last && last.toA === c.fromA && last.toB === c.fromB) out[out.length - 1] = new Change(last.fromA, c.toA, last.fromB, c.toB);
  else out.push(c);
}

function refine(a: string, b: string, fromA: number, toA: number, fromB: number, toB: number, out: Change[]) {
  const whole = new Change(fromA, toA, fromB, toB);
  const lenA = toA - fromA;
  const lenB = toB - fromB;
  if (lenA === 0 || lenB === 0 || lenA + lenB > REFINE_MAX_CHARS) {
    push(out, whole);
    return;
  }
  const inner = presentableDiff(a.slice(fromA, toA), b.slice(fromB, toB), { scanLimit: 500 });
  const changed = inner.reduce((n, c) => n + (c.toA - c.fromA) + (c.toB - c.fromB), 0);
  if (changed > (lenA + lenB) * REFINE_MAX_CHANGED) {
    push(out, whole);
    return;
  }
  for (const c of inner) push(out, new Change(c.fromA + fromA, c.toA + fromA, c.fromB + fromB, c.toB + fromB));
}

/** `DiffConfig.override` for the merge view: the changes from `a` to `b`, found line by line. */
export function lineDiff(a: string, b: string): readonly Change[] {
  const ids = new Map<string, number>();
  const la = encode(a, ids);
  const lb = la && encode(b, ids);
  // more distinct lines than there are code units: the package's own way
  if (!la || !lb) return presentableDiff(a, b, { scanLimit: 500 });

  const out: Change[] = [];
  for (const c of diff(la.code, lb.code, { timeout: 2_000 })) {
    const lines = c.toA - c.fromA;
    if (lines > 1 && lines === c.toB - c.fromB) {
      // as many lines on each side (a mirror swapped in every URL of a
      // lock file): each line against its counterpart, as VS Code pairs them
      for (let i = 0; i < lines; i++) {
        const ia = c.fromA + i;
        const ib = c.fromB + i;
        refine(a, b, la.starts[ia]!, la.starts[ia + 1]!, lb.starts[ib]!, lb.starts[ib + 1]!, out);
      }
    } else {
      refine(a, b, la.starts[c.fromA]!, la.starts[c.toA]!, lb.starts[c.fromB]!, lb.starts[c.toB]!, out);
    }
  }
  return out;
}
