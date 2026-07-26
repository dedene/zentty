/**
 * Pure render projection for the Conversation tab: folds raw transcript entries
 * into display items before the list renders them. Pairs each tool call with
 * its result, collapses long bursts of finished tool activity into one
 * expandable group, and merges repeated system markers — so the list shows
 * conversation, not plumbing. Kept UI-free so the transforms are unit-tested
 * in isolation (mirrors `transcript.ts`).
 */

import type { TranscriptEntry } from '@zentty/wire';

/** Runs of at least this many tool items collapse into a single group row. */
export const TOOL_GROUP_THRESHOLD = 4;

export interface ToolPair {
  call?: TranscriptEntry;
  result?: TranscriptEntry;
}

export type TranscriptRenderItem =
  | { kind: 'user'; id: string; entry: TranscriptEntry }
  | { kind: 'assistant'; id: string; entry: TranscriptEntry }
  | { kind: 'system'; id: string; text: string; repeat: number }
  | ({ kind: 'tool'; id: string } & ToolPair)
  | { kind: 'toolGroup'; id: string; tools: ToolPair[]; failedCount: number };

const RUNNING_STATUSES = new Set(['running', 'pending', 'in_progress', 'starting']);
const FAILED_STATUSES = new Set(['error', 'failed']);

function isRunning(pair: ToolPair): boolean {
  const status = pair.call?.status ?? pair.result?.status;
  return status !== undefined && RUNNING_STATUSES.has(status);
}

function isFailed(pair: ToolPair): boolean {
  const status = pair.call?.status ?? pair.result?.status;
  return status !== undefined && FAILED_STATUSES.has(status);
}

function pairId(pair: ToolPair): string {
  return pair.call?.id ?? pair.result?.id ?? 'tool-unknown';
}

/** Flush a pending run of tool pairs into either individual items or a group. */
function flushToolRun(run: ToolPair[], out: TranscriptRenderItem[]): void {
  if (run.length === 0) {
    return;
  }
  // A still-running trailing tool stays visible as its own row; only the
  // finished prefix is eligible for collapsing. Copy before the caller's
  // buffer is cleared below.
  let groupable = [...run];
  let tail: ToolPair | undefined;
  if (isRunning(run[run.length - 1])) {
    groupable = run.slice(0, -1);
    tail = run[run.length - 1];
  }
  if (groupable.length >= TOOL_GROUP_THRESHOLD) {
    out.push({
      kind: 'toolGroup',
      id: `group:${pairId(groupable[0])}`,
      tools: groupable,
      failedCount: groupable.filter(isFailed).length,
    });
  } else {
    for (const pair of groupable) {
      out.push({ kind: 'tool', id: pairId(pair), ...pair });
    }
  }
  if (tail) {
    out.push({ kind: 'tool', id: pairId(tail), ...tail });
  }
  run.length = 0;
}

export function projectTranscript(entries: TranscriptEntry[]): TranscriptRenderItem[] {
  const items: TranscriptRenderItem[] = [];
  const toolRun: ToolPair[] = [];

  for (const entry of entries) {
    switch (entry.role) {
      case 'tool_use':
        toolRun.push({ call: entry });
        break;
      case 'tool_result': {
        // Attach to the most recent unpaired call in the current run;
        // an orphan result becomes its own tool item.
        const open = [...toolRun].reverse().find((pair) => pair.call && !pair.result);
        if (open) {
          open.result = entry;
        } else {
          toolRun.push({ result: entry });
        }
        break;
      }
      case 'system': {
        flushToolRun(toolRun, items);
        const text = entry.text ?? entry.status ?? 'system';
        const last = items[items.length - 1];
        if (last?.kind === 'system' && last.text === text) {
          last.repeat += 1;
        } else {
          items.push({ kind: 'system', id: entry.id, text, repeat: 1 });
        }
        break;
      }
      case 'user':
        flushToolRun(toolRun, items);
        items.push({ kind: 'user', id: entry.id, entry });
        break;
      default:
        flushToolRun(toolRun, items);
        items.push({ kind: 'assistant', id: entry.id, entry });
        break;
    }
  }
  flushToolRun(toolRun, items);
  return items;
}
