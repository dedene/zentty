import { Ionicons } from '@expo/vector-icons';
import { useCallback, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import type { TranscriptUnavailableReason } from '@zentty/wire';
import type { TranscriptState } from '@/store';
import {
  projectTranscript,
  type ToolPair,
  type TranscriptRenderItem,
} from '@/store/transcriptProjection';
import { parseInlineSpans, parseMarkdownBlocks } from '@/lib/markdownLite';
import { EmptyState } from './EmptyState';
import { colors, mono, radius, space, type } from '@/theme';

const UNAVAILABLE: Record<TranscriptUnavailableReason, { title: string; message: string }> = {
  no_adapter: {
    title: 'No conversation view',
    message: 'This tool has no transcript adapter yet. Use the Terminal tab to follow along.',
  },
  session_ended: {
    title: 'Session ended',
    message: 'The agent session finished. Its transcript is no longer live.',
  },
  file_missing: {
    title: 'Transcript unavailable',
    message: 'The session file could not be found — it may have rotated or been resumed under a new id.',
  },
};

/**
 * Native phone-width transcript for adapted tools (spec §2.5). Entries pass
 * through `projectTranscript` first: tool calls pair with their results,
 * long tool bursts collapse into one expandable group, and repeated system
 * markers merge — the list shows the conversation, not the plumbing.
 * Assistant prose renders full-width with lightweight markdown; only user
 * messages get bubble chrome. Approvals reuse the pinned quick-actions bar
 * in the parent, so this view is purely the conversation.
 */
export function TranscriptView({ transcript }: { transcript: TranscriptState }) {
  const listRef = useRef<FlatList<TranscriptRenderItem>>(null);
  const stick = useRef(true);

  const items = useMemo(
    () => (transcript.status === 'active' ? projectTranscript(transcript.entries) : []),
    [transcript.status, transcript.entries],
  );

  const onContentSizeChange = useCallback(() => {
    if (stick.current) {
      listRef.current?.scrollToEnd({ animated: false });
    }
  }, []);

  if (transcript.status === 'unavailable') {
    const info = UNAVAILABLE[transcript.unavailableReason ?? 'no_adapter'];
    return <EmptyState icon="chatbubbles-outline" title={info.title} message={info.message} />;
  }

  if (transcript.status === 'loading' || transcript.status === 'idle') {
    return (
      <View style={styles.loading}>
        <ActivityIndicator size="small" color={colors.textFaint} />
        <Text style={type.dim}>Loading conversation…</Text>
      </View>
    );
  }

  if (items.length === 0) {
    return (
      <EmptyState
        icon="chatbubble-ellipses-outline"
        title="No messages yet"
        message="This conversation is empty so far. New messages will appear here live."
      />
    );
  }

  return (
    <FlatList
      ref={listRef}
      data={items}
      keyExtractor={(item) => item.id}
      renderItem={({ item }) => <Row item={item} />}
      contentContainerStyle={styles.list}
      onContentSizeChange={onContentSizeChange}
      ListHeaderComponent={
        transcript.truncated ? (
          <Text style={styles.truncated}>Earlier messages are truncated</Text>
        ) : null
      }
      ItemSeparatorComponent={() => <View style={styles.gap} />}
    />
  );
}

function Row({ item }: { item: TranscriptRenderItem }) {
  switch (item.kind) {
    case 'toolGroup':
      return <ToolGroupRow tools={item.tools} failedCount={item.failedCount} />;
    case 'tool':
      return <ToolCard pair={item} />;
    case 'system':
      return (
        <Text style={styles.system}>
          {item.text}
          {item.repeat > 1 ? ` ×${item.repeat}` : ''}
        </Text>
      );
    case 'user':
      return (
        <View style={styles.userBubble}>
          <MarkdownText text={item.entry.text ?? ''} />
        </View>
      );
    default:
      return (
        <View style={styles.assistant}>
          <MarkdownText text={item.entry.text ?? ''} />
        </View>
      );
  }
}

/** Fenced code → mono block; prose lines → bold/inline-code aware text. */
function MarkdownText({ text }: { text: string }) {
  const blocks = useMemo(() => parseMarkdownBlocks(text), [text]);
  return (
    <View style={styles.markdown}>
      {blocks.map((block, index) =>
        block.type === 'code' ? (
          <View key={index} style={styles.codeBlock}>
            <Text style={styles.codeText}>{block.text}</Text>
          </View>
        ) : (
          <Text key={index} style={styles.bodyText}>
            {parseInlineSpans(block.text).map((span, spanIndex) => (
              <Text
                key={spanIndex}
                style={[span.bold && styles.boldSpan, span.code && styles.codeSpan]}
              >
                {span.text}
              </Text>
            ))}
          </Text>
        ),
      )}
    </View>
  );
}

const RUNNING = new Set(['running', 'pending', 'in_progress', 'starting']);
const FAILED = new Set(['error', 'failed']);

/** One card per tool call: name + status up top, result summary underneath,
 * tap to reveal the raw input and full result. */
function ToolCard({ pair }: { pair: ToolPair }) {
  const [open, setOpen] = useState(false);
  const status = pair.call?.status ?? pair.result?.status;
  const detail = formatToolInput(pair.call?.toolInput);
  const summary = pair.result?.toolResultSummary ?? pair.result?.text;
  const expandable = Boolean(detail || (summary && summary.length > 160));

  return (
    <Pressable
      onPress={() => expandable && setOpen((v) => !v)}
      style={styles.toolCard}
      accessibilityRole="button"
    >
      <View style={styles.toolHead}>
        {status && RUNNING.has(status) ? (
          <ActivityIndicator size="small" color={colors.starting} />
        ) : (
          <Ionicons
            name={status && FAILED.has(status) ? 'alert-circle-outline' : 'construct-outline'}
            size={15}
            color={status && FAILED.has(status) ? colors.danger : colors.starting}
          />
        )}
        <Text style={styles.toolName} numberOfLines={1}>
          {pair.call?.toolName ?? 'tool'}
        </Text>
        {status ? <Text style={styles.toolStatus}>{status}</Text> : null}
        {expandable ? (
          <Ionicons
            name={open ? 'chevron-up' : 'chevron-down'}
            size={15}
            color={colors.textFaint}
            style={styles.chevron}
          />
        ) : null}
      </View>
      {open && detail ? <Text style={styles.toolDetail}>{detail}</Text> : null}
      {summary ? (
        <Text style={styles.resultText} numberOfLines={open ? undefined : 4}>
          {summary}
        </Text>
      ) : null}
    </Pressable>
  );
}

/** Collapsed burst of finished tool calls: "Ran N tools · M failed". */
function ToolGroupRow({ tools, failedCount }: { tools: ToolPair[]; failedCount: number }) {
  const [open, setOpen] = useState(false);
  const title = useMemo(() => {
    const parts = [`Ran ${tools.length} tools`];
    if (failedCount > 0) {
      parts.push(`${failedCount} failed`);
    }
    return parts.join(' · ');
  }, [tools.length, failedCount]);

  return (
    <View style={styles.groupWrap}>
      <Pressable
        onPress={() => setOpen((v) => !v)}
        style={styles.groupHead}
        accessibilityRole="button"
        accessibilityLabel={title}
        accessibilityHint={open ? 'Collapse tool calls' : 'Expand tool calls'}
      >
        <Ionicons name="terminal-outline" size={15} color={colors.textFaint} />
        <Text style={styles.groupTitle}>{title}</Text>
        <Ionicons
          name={open ? 'chevron-up' : 'chevron-down'}
          size={14}
          color={colors.textFaint}
          style={styles.chevron}
        />
      </Pressable>
      {open
        ? tools.map((pair, index) => (
            <ToolCard key={pair.call?.id ?? pair.result?.id ?? index} pair={pair} />
          ))
        : null}
    </View>
  );
}

function formatToolInput(input: unknown): string | undefined {
  if (input === undefined || input === null) {
    return undefined;
  }
  if (typeof input === 'string') {
    return input;
  }
  try {
    return JSON.stringify(input, null, 2);
  } catch {
    return String(input);
  }
}

const styles = StyleSheet.create({
  list: {
    padding: space.lg,
  },
  gap: {
    height: space.md,
  },
  loading: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
  },
  truncated: {
    textAlign: 'center',
    color: colors.textFaint,
    fontSize: 12,
    marginBottom: space.md,
  },
  userBubble: {
    alignSelf: 'flex-end',
    maxWidth: '88%',
    paddingVertical: space.sm,
    paddingHorizontal: space.md,
    borderRadius: radius.md,
    backgroundColor: colors.accentDim,
  },
  assistant: {
    alignSelf: 'stretch',
  },
  markdown: {
    gap: space.sm,
  },
  bodyText: {
    color: colors.text,
    fontSize: 15,
    lineHeight: 22,
  },
  boldSpan: {
    fontWeight: '700',
  },
  codeSpan: {
    fontFamily: mono,
    fontSize: 13,
    color: colors.textDim,
    backgroundColor: colors.surface,
  },
  codeBlock: {
    backgroundColor: colors.surface,
    borderRadius: radius.sm,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    padding: space.md,
  },
  codeText: {
    fontFamily: mono,
    fontSize: 12,
    lineHeight: 17,
    color: colors.textDim,
  },
  system: {
    textAlign: 'center',
    color: colors.textFaint,
    fontSize: 12,
  },
  toolCard: {
    alignSelf: 'stretch',
    padding: space.md,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    gap: space.sm,
  },
  toolHead: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
  },
  toolName: {
    flexShrink: 1,
    color: colors.text,
    fontSize: 14,
    fontWeight: '600',
    fontFamily: mono,
  },
  toolStatus: {
    color: colors.textFaint,
    fontSize: 12,
  },
  chevron: {
    marginLeft: 'auto',
  },
  toolDetail: {
    fontFamily: mono,
    fontSize: 12,
    color: colors.textDim,
  },
  resultText: {
    fontFamily: mono,
    fontSize: 12,
    lineHeight: 17,
    color: colors.textDim,
  },
  groupWrap: {
    gap: space.md,
  },
  groupHead: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: space.sm,
    paddingVertical: space.sm,
    paddingHorizontal: space.md,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  groupTitle: {
    color: colors.textDim,
    fontSize: 13,
  },
});
