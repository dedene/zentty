import type { PaneState } from '@zentty/wire';

import { paneStateColor, paneStateLabel } from '@/lib/labels';

import { Pill } from './Pill';

/** Badge for a pane's agent state (Running / Needs input / Stopped / …). */
export function StateBadge({ state }: { state: PaneState }) {
  return <Pill label={paneStateLabel(state)} color={paneStateColor(state)} />;
}
