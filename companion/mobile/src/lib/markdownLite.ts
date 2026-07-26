/**
 * Minimal markdown support for agent prose in the Conversation tab: fenced
 * code blocks, inline `code`, **bold**, and headings-as-bold. Deliberately not
 * a full markdown engine — agent output is markdown-heavy and rendering the
 * raw markers (literal `**`) reads as noise, but a full renderer is a heavy
 * dependency this view doesn't need. Pure functions, unit-tested.
 */

export type MarkdownBlock = { type: 'text' | 'code'; text: string };

export interface InlineSpan {
  text: string;
  bold?: boolean;
  code?: boolean;
}

/** Split prose into text blocks and fenced code blocks (``` fences). */
export function parseMarkdownBlocks(raw: string): MarkdownBlock[] {
  const blocks: MarkdownBlock[] = [];
  const lines = raw.split('\n');
  let buffer: string[] = [];
  let inCode = false;

  const flush = (type: 'text' | 'code') => {
    const text = buffer.join('\n').replace(/^\n+|\n+$/g, '');
    if (text.length > 0) {
      blocks.push({ type, text });
    }
    buffer = [];
  };

  for (const line of lines) {
    if (line.trimStart().startsWith('```')) {
      flush(inCode ? 'code' : 'text');
      inCode = !inCode;
      continue;
    }
    buffer.push(line);
  }
  flush(inCode ? 'code' : 'text');
  return blocks;
}

/**
 * Tokenize one text block into inline spans. Unbalanced markers stay literal
 * so malformed or streaming-truncated markdown never eats content.
 */
export function parseInlineSpans(raw: string): InlineSpan[] {
  const heading = raw.match(/^#{1,6}\s+(.*)$/);
  if (heading) {
    return [{ text: heading[1], bold: true }];
  }

  const spans: InlineSpan[] = [];
  let plain = '';
  let i = 0;

  const pushPlain = () => {
    if (plain.length > 0) {
      spans.push({ text: plain });
      plain = '';
    }
  };

  while (i < raw.length) {
    if (raw.startsWith('**', i)) {
      const close = raw.indexOf('**', i + 2);
      if (close > i + 2) {
        pushPlain();
        spans.push({ text: raw.slice(i + 2, close), bold: true });
        i = close + 2;
        continue;
      }
    }
    if (raw[i] === '`') {
      const close = raw.indexOf('`', i + 1);
      if (close > i + 1) {
        pushPlain();
        spans.push({ text: raw.slice(i + 1, close), code: true });
        i = close + 1;
        continue;
      }
    }
    plain += raw[i];
    i += 1;
  }
  pushPlain();
  return spans;
}
