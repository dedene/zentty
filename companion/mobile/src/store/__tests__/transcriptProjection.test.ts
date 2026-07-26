import { beforeEach, describe, expect, it } from '@jest/globals';

import type { TranscriptEntry } from '@zentty/wire';

import {
  projectTranscript,
  TOOL_GROUP_THRESHOLD,
  type TranscriptRenderItem,
} from '../transcriptProjection';

let seq = 0;
function entry(partial: Partial<TranscriptEntry> & { role: TranscriptEntry['role'] }): TranscriptEntry {
  seq += 1;
  return { id: `e${seq}`, ...partial };
}

function kinds(items: TranscriptRenderItem[]): string[] {
  return items.map((item) => item.kind);
}

beforeEach(() => {
  seq = 0;
});

describe('projectTranscript', () => {
  it('renders user and assistant entries as standalone items in order', () => {
    const items = projectTranscript([
      entry({ role: 'user', text: 'hi' }),
      entry({ role: 'assistant', text: 'hello' }),
    ]);
    expect(kinds(items)).toEqual(['user', 'assistant']);
  });

  it('pairs a tool_result with the preceding unpaired tool_use', () => {
    const items = projectTranscript([
      entry({ role: 'tool_use', toolName: 'Bash', status: 'done' }),
      entry({ role: 'tool_result', toolResultSummary: 'ok' }),
    ]);
    expect(items).toHaveLength(1);
    const item = items[0];
    expect(item.kind).toBe('tool');
    if (item.kind === 'tool') {
      expect(item.call?.toolName).toBe('Bash');
      expect(item.result?.toolResultSummary).toBe('ok');
    }
  });

  it('renders an orphan tool_result as its own tool item', () => {
    const items = projectTranscript([entry({ role: 'tool_result', toolResultSummary: 'late' })]);
    expect(items).toHaveLength(1);
    expect(items[0].kind).toBe('tool');
  });

  it('collapses a long run of finished tool calls into a group with failure counts', () => {
    const run = Array.from({ length: TOOL_GROUP_THRESHOLD + 1 }, (_, i) =>
      entry({ role: 'tool_use', toolName: `t${i}`, status: i === 0 ? 'error' : 'done' }),
    );
    const items = projectTranscript([entry({ role: 'user', text: 'go' }), ...run]);
    expect(kinds(items)).toEqual(['user', 'toolGroup']);
    const group = items[1];
    if (group.kind === 'toolGroup') {
      expect(group.tools).toHaveLength(TOOL_GROUP_THRESHOLD + 1);
      expect(group.failedCount).toBe(1);
    }
  });

  it('keeps short tool runs ungrouped', () => {
    const run = Array.from({ length: TOOL_GROUP_THRESHOLD - 1 }, (_, i) =>
      entry({ role: 'tool_use', toolName: `t${i}`, status: 'done' }),
    );
    const items = projectTranscript(run);
    expect(items.every((item) => item.kind === 'tool')).toBe(true);
  });

  it('keeps a still-running trailing tool out of the collapsed group', () => {
    const run = Array.from({ length: TOOL_GROUP_THRESHOLD + 1 }, (_, i) =>
      entry({ role: 'tool_use', toolName: `t${i}`, status: 'done' }),
    );
    const running = entry({ role: 'tool_use', toolName: 'live', status: 'running' });
    const items = projectTranscript([...run, running]);
    expect(kinds(items)).toEqual(['toolGroup', 'tool']);
    const tail = items[1];
    if (tail.kind === 'tool') {
      expect(tail.call?.toolName).toBe('live');
    }
  });

  it('a tool run interrupted by an assistant message forms separate segments', () => {
    const runA = Array.from({ length: TOOL_GROUP_THRESHOLD }, () =>
      entry({ role: 'tool_use', toolName: 'a', status: 'done' }),
    );
    const runB = Array.from({ length: TOOL_GROUP_THRESHOLD }, () =>
      entry({ role: 'tool_use', toolName: 'b', status: 'done' }),
    );
    const items = projectTranscript([...runA, entry({ role: 'assistant', text: 'mid' }), ...runB]);
    expect(kinds(items)).toEqual(['toolGroup', 'assistant', 'toolGroup']);
  });

  it('collapses consecutive identical system rows with a repeat count', () => {
    const items = projectTranscript([
      entry({ role: 'system', text: 'session_start' }),
      entry({ role: 'system', text: 'session_start' }),
      entry({ role: 'system', text: 'session_start' }),
      entry({ role: 'system', text: 'stop' }),
    ]);
    expect(kinds(items)).toEqual(['system', 'system']);
    const first = items[0];
    if (first.kind === 'system') {
      expect(first.text).toBe('session_start');
      expect(first.repeat).toBe(3);
    }
  });

  it('is stable for ids: same input yields same item ids', () => {
    const entries = [
      entry({ role: 'tool_use', toolName: 'x', status: 'done' }),
      entry({ role: 'tool_result', toolResultSummary: 'ok' }),
    ];
    const a = projectTranscript(entries).map((item) => item.id);
    const b = projectTranscript(entries).map((item) => item.id);
    expect(a).toEqual(b);
  });
});
