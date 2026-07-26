/** @jest-environment node */
import { beforeEach, describe, expect, it, jest, afterEach } from '@jest/globals';
import { AppState, type AppStateStatus } from 'react-native';

// The store is mocked down to getState(); foregroundRecovery only reads
// ready/hydrate/wakeConnections from it.
const mockStoreState = {
  ready: true,
  hydrate: jest.fn<() => Promise<void>>(),
  wakeConnections: jest.fn<() => void>(),
};

jest.mock('@/store', () => ({
  useCompanionStore: { getState: () => mockStoreState },
}));

// Imported after the mock is registered.
// eslint-disable-next-line import/first
import { subscribeForegroundRecovery } from '../foregroundRecovery';

describe('subscribeForegroundRecovery', () => {
  let handlers: Array<(next: AppStateStatus) => void>;
  let mockRemove: jest.Mock<() => void>;

  beforeEach(() => {
    handlers = [];
    mockRemove = jest.fn();
    jest.clearAllMocks();
    mockStoreState.ready = true;
    mockStoreState.hydrate.mockResolvedValue(undefined);
    jest.spyOn(AppState, 'addEventListener').mockImplementation((_event, handler) => {
      handlers.push(handler);
      return { remove: mockRemove } as unknown as ReturnType<typeof AppState.addEventListener>;
    });
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('wakes connections when the app foregrounds, ignoring other transitions', () => {
    subscribeForegroundRecovery();
    expect(handlers).toHaveLength(1);

    handlers[0]('active');
    expect(mockStoreState.wakeConnections).toHaveBeenCalledTimes(1);
    // Already hydrated: no re-hydrate.
    expect(mockStoreState.hydrate).not.toHaveBeenCalled();

    handlers[0]('background');
    handlers[0]('inactive');
    expect(mockStoreState.wakeConnections).toHaveBeenCalledTimes(1);
  });

  it('retries a failed hydration on foreground, swallowing the rejection', async () => {
    mockStoreState.ready = false;
    mockStoreState.hydrate.mockRejectedValue(new Error('keychain busy'));
    subscribeForegroundRecovery();

    handlers[0]('active');
    expect(mockStoreState.hydrate).toHaveBeenCalledTimes(1);
    expect(mockStoreState.wakeConnections).toHaveBeenCalledTimes(1);
    // Let the swallowed rejection settle; nothing should escape as unhandled.
    await new Promise((r) => setTimeout(r, 0));
  });

  it('stops listening after unsubscribe', () => {
    const unsubscribe = subscribeForegroundRecovery();
    unsubscribe();
    expect(mockRemove).toHaveBeenCalledTimes(1);
  });
});
