import { describe, expect, it } from '@jest/globals';

import type { TranscriptEntry } from '@zentty/wire';

import {
  applyTranscriptDelta,
  applyTranscriptSnapshot,
  applyTranscriptUnavailable,
  initialTranscript,
  loadingTranscript,
} from '../transcript';

function entry(id: string, overrides: Partial<TranscriptEntry> = {}): TranscriptEntry {
  return { id, role: 'assistant', text: id, ...overrides };
}

describe('transcript reducer', () => {
  it('adopts a snapshot as the active baseline', () => {
    const state = applyTranscriptSnapshot({
      sessionId: 's1',
      entries: [entry('a'), entry('b')],
      truncated: true,
    });
    expect(state.status).toBe('active');
    expect(state.sessionId).toBe('s1');
    expect(state.entries.map((e) => e.id)).toEqual(['a', 'b']);
    expect(state.truncated).toBe(true);
  });

  it('appends new delta entries in order', () => {
    const base = applyTranscriptSnapshot({ sessionId: 's', entries: [entry('a')], truncated: false });
    const next = applyTranscriptDelta(base, { entries: [entry('b'), entry('c')] });
    expect(next.entries.map((e) => e.id)).toEqual(['a', 'b', 'c']);
  });

  it('upserts an existing entry by id (tool_use revised by its result)', () => {
    const base = applyTranscriptSnapshot({
      sessionId: 's',
      entries: [entry('t1', { role: 'tool_use', status: 'running' })],
      truncated: false,
    });
    const next = applyTranscriptDelta(base, {
      entries: [entry('t1', { role: 'tool_use', status: 'done', toolResultSummary: 'ok' })],
    });
    expect(next.entries).toHaveLength(1);
    expect(next.entries[0].status).toBe('done');
    expect(next.entries[0].toolResultSummary).toBe('ok');
  });

  it('is a no-op for an empty delta', () => {
    const base = applyTranscriptSnapshot({ sessionId: 's', entries: [entry('a')], truncated: false });
    expect(applyTranscriptDelta(base, { entries: [] })).toBe(base);
  });

  it('marks unavailable with a reason', () => {
    const state = applyTranscriptUnavailable(initialTranscript, 'session_ended');
    expect(state.status).toBe('unavailable');
    expect(state.unavailableReason).toBe('session_ended');
  });

  it('recovers to active when a delta arrives after unavailable', () => {
    const gone = applyTranscriptUnavailable(
      applyTranscriptSnapshot({ sessionId: 's', entries: [entry('a')], truncated: false }),
      'file_missing',
    );
    const back = applyTranscriptDelta(gone, { entries: [entry('b')] });
    expect(back.status).toBe('active');
    expect(back.unavailableReason).toBeUndefined();
    expect(back.entries.map((e) => e.id)).toEqual(['a', 'b']);
  });

  it('loadingTranscript clears a prior unavailable reason', () => {
    const gone = applyTranscriptUnavailable(initialTranscript, 'no_adapter');
    const loading = loadingTranscript(gone);
    expect(loading.status).toBe('loading');
    expect(loading.unavailableReason).toBeUndefined();
  });
});
