import { describe, expect, it } from '@jest/globals';

import { parseInlineSpans, parseMarkdownBlocks } from '../markdownLite';

describe('parseMarkdownBlocks', () => {
  it('splits fenced code from prose', () => {
    const blocks = parseMarkdownBlocks('before\n```ts\nconst a = 1;\n```\nafter');
    expect(blocks).toEqual([
      { type: 'text', text: 'before' },
      { type: 'code', text: 'const a = 1;' },
      { type: 'text', text: 'after' },
    ]);
  });

  it('treats an unterminated fence as code to the end', () => {
    const blocks = parseMarkdownBlocks('x\n```\nstill code');
    expect(blocks).toEqual([
      { type: 'text', text: 'x' },
      { type: 'code', text: 'still code' },
    ]);
  });

  it('returns plain prose as a single text block', () => {
    expect(parseMarkdownBlocks('just text')).toEqual([{ type: 'text', text: 'just text' }]);
  });
});

describe('parseInlineSpans', () => {
  it('parses bold and inline code spans', () => {
    expect(parseInlineSpans('a **bold** and `code` end')).toEqual([
      { text: 'a ' },
      { text: 'bold', bold: true },
      { text: ' and ' },
      { text: 'code', code: true },
      { text: ' end' },
    ]);
  });

  it('leaves unbalanced markers as literal text', () => {
    expect(parseInlineSpans('a ** b')).toEqual([{ text: 'a ** b' }]);
    expect(parseInlineSpans('tick ` alone')).toEqual([{ text: 'tick ` alone' }]);
  });

  it('renders heading lines as bold', () => {
    expect(parseInlineSpans('## Title')).toEqual([{ text: 'Title', bold: true }]);
  });
});
