import { describe, expect, it } from '@jest/globals';

import { APP_SCHEME, BONJOUR_SERVICE_TYPE, PROTOCOL_VERSION } from '../config';

describe('app config', () => {
  it('speaks wire protocol v1', () => {
    expect(PROTOCOL_VERSION).toBe(1);
  });

  it('registers the zentty deep-link scheme', () => {
    expect(APP_SCHEME).toBe('zentty');
  });

  it('advertises the shared Bonjour service type', () => {
    expect(BONJOUR_SERVICE_TYPE).toBe('_zentty._tcp');
  });
});
