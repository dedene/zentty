import { z } from 'zod';

// input.* — phone-originated input into a pane.

/** Named keys the phone can inject. */
export const InputKey = z.enum([
  'enter',
  'escape',
  'tab',
  'up',
  'down',
  'left',
  'right',
  'ctrl_c',
  'ctrl_d',
  'ctrl_z',
  'ctrl_r',
]);
export type InputKey = z.infer<typeof InputKey>;

/** phone -> mac. UTF-8 passthrough. */
export const InputText = z.object({
  paneId: z.string(),
  text: z.string(),
});

/** phone -> mac. */
export const InputKeyMessage = z.object({
  paneId: z.string(),
  key: InputKey,
});

/** phone -> mac. `actionId` from PaneSummary-attached quick actions. */
export const InputQuickAction = z.object({
  paneId: z.string(),
  actionId: z.string(),
});

/** mac -> phone. Correlated to the input frame via the envelope `replyTo`. */
export const InputAck = z.object({
  ok: z.boolean(),
  error: z.string().optional(),
});

export const inputMessages = {
  'input.text': InputText,
  'input.key': InputKeyMessage,
  'input.quickAction': InputQuickAction,
  'input.ack': InputAck,
} as const;
