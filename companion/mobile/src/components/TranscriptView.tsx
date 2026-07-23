import { Ionicons } from '@expo/vector-icons';
import { useCallback, useRef, useState } from 'react';
import { ActivityIndicator, FlatList, Pressable, StyleSheet, Text, View } from 'react-native';

import type { TranscriptEntry, TranscriptUnavailableReason } from '@zentty/wire';
import type { TranscriptState } from '@/store';
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
 * Native phone-width transcript for adapted tools (spec §2.5): message bubbles,
 * collapsible tool-call cards, and tool results. Approvals reuse the pinned
 * quick-actions bar in the parent, so this view is purely the conversation.
 */
export function TranscriptView({ transcript }: { transcript: TranscriptState }) {
  const listRef = useRef<FlatList<TranscriptEntry>>(null);
  const stick = useRef(true);

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

  if (transcript.entries.length === 0) {
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
      data={transcript.entries}
      keyExtractor={(entry) => entry.id}
      renderItem={({ item }) => <Entry entry={item} />}
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

function Entry({ entry }: { entry: TranscriptEntry }) {
  switch (entry.role) {
    case 'tool_use':
      return <ToolCallCard entry={entry} />;
    case 'tool_result':
      return <ToolResultCard entry={entry} />;
    case 'system':
      return <Text style={styles.system}>{entry.text ?? entry.status ?? 'system'}</Text>;
    case 'user':
      return (
        <View style={[styles.bubble, styles.userBubble]}>
          <Text style={styles.bubbleText}>{entry.text ?? ''}</Text>
        </View>
      );
    default:
      return (
        <View style={[styles.bubble, styles.assistantBubble]}>
          <Text style={styles.bubbleText}>{entry.text ?? ''}</Text>
        </View>
      );
  }
}

function ToolCallCard({ entry }: { entry: TranscriptEntry }) {
  const [open, setOpen] = useState(false);
  const detail = formatToolInput(entry.toolInput);
  return (
    <Pressable
      onPress={() => detail && setOpen((v) => !v)}
      style={styles.toolCard}
      accessibilityRole="button"
    >
      <View style={styles.toolHead}>
        <Ionicons name="construct-outline" size={15} color={colors.starting} />
        <Text style={styles.toolName}>{entry.toolName ?? 'tool'}</Text>
        {entry.status ? <Text style={styles.toolStatus}>{entry.status}</Text> : null}
        {detail ? (
          <Ionicons
            name={open ? 'chevron-up' : 'chevron-down'}
            size={15}
            color={colors.textFaint}
            style={styles.chevron}
          />
        ) : null}
      </View>
      {open && detail ? <Text style={styles.toolDetail}>{detail}</Text> : null}
    </Pressable>
  );
}

function ToolResultCard({ entry }: { entry: TranscriptEntry }) {
  return (
    <View style={styles.resultCard}>
      <Ionicons name="return-down-forward-outline" size={14} color={colors.online} />
      <Text style={styles.resultText} numberOfLines={8}>
        {entry.toolResultSummary ?? entry.text ?? 'done'}
      </Text>
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
  bubble: {
    maxWidth: '92%',
    paddingVertical: space.sm,
    paddingHorizontal: space.md,
    borderRadius: radius.md,
  },
  userBubble: {
    alignSelf: 'flex-end',
    backgroundColor: colors.accentDim,
  },
  assistantBubble: {
    alignSelf: 'flex-start',
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  bubbleText: {
    color: colors.text,
    fontSize: 15,
    lineHeight: 21,
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
  resultCard: {
    flexDirection: 'row',
    alignSelf: 'stretch',
    gap: space.sm,
    padding: space.md,
    borderRadius: radius.md,
    backgroundColor: '#0C1410',
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: '#1E3A24',
  },
  resultText: {
    flex: 1,
    fontFamily: mono,
    fontSize: 12,
    color: colors.textDim,
  },
});
