import { describe, expect, it } from '@jest/globals';

import { APP_SCHEME } from '../config';

describe('app config', () => {
  it('registers the zentty deep-link scheme', () => {
    expect(APP_SCHEME).toBe('zentty');
  });
});
