import { CameraView, useCameraPermissions } from 'expo-camera';
import { router } from 'expo-router';
import { useCallback, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Linking,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

import { Button, InlineNotice, Screen } from '@/components';
import { ConnectionFailedError, PairingRejectedError } from '@/core';
import {
  PairingExpiredError,
  PairingParseError,
  pairWithOffer,
  parseOffer,
  useCompanionStore,
} from '@/store';
import { colors, radius, space, type } from '@/theme';

type Mode = 'camera' | 'manual';

type Status =
  | { k: 'idle' }
  | { k: 'pairing'; macName?: string }
  | { k: 'error'; tone: 'error' | 'warning'; title: string; message: string };

/**
 * Pairing entry point: scan the Mac's QR offer (or paste the code), run the
 * pairing handshake, persist the Mac, and hand off to the Macs list. Every
 * failure resolves to one calm inline notice — never stacked alerts.
 */
export default function ScanScreen() {
  const [permission, requestPermission] = useCameraPermissions();
  const [mode, setMode] = useState<Mode>('camera');
  const [status, setStatus] = useState<Status>({ k: 'idle' });
  const [manual, setManual] = useState('');
  const busy = useRef(false);

  const addPairedMac = useCompanionStore((s) => s.addPairedMac);

  const reset = useCallback(() => {
    busy.current = false;
    setStatus({ k: 'idle' });
  }, []);

  const pair = useCallback(
    async (raw: string) => {
      if (busy.current) {
        return;
      }
      busy.current = true;
      setStatus({ k: 'pairing' });
      try {
        const offer = parseOffer(raw);
        const mac = await pairWithOffer(offer);
        await addPairedMac(mac);
        router.replace('/');
      } catch (error) {
        busy.current = false;
        setStatus(errorStatus(error));
      }
    },
    [addPairedMac],
  );

  const onBarcode = useCallback(
    ({ data }: { data: string }) => {
      if (!busy.current && status.k === 'idle') {
        void pair(data);
      }
    },
    [pair, status.k],
  );

  return (
    <Screen edges={['bottom', 'left', 'right']}>
      <View style={styles.container}>
        {status.k === 'error' ? (
          <InlineNotice tone={status.tone} title={status.title} message={status.message}>
            <Button label="Try again" onPress={reset} icon="refresh" variant="secondary" />
          </InlineNotice>
        ) : null}

        {mode === 'camera' ? (
          <CameraPane
            permission={permission}
            onRequest={requestPermission}
            onBarcode={onBarcode}
            status={status}
          />
        ) : (
          <ManualPane
            value={manual}
            onChange={setManual}
            onSubmit={() => void pair(manual)}
            status={status}
          />
        )}

        <Button
          label={mode === 'camera' ? 'Enter code instead' : 'Scan QR code'}
          onPress={() => {
            reset();
            setMode(mode === 'camera' ? 'manual' : 'camera');
          }}
          icon={mode === 'camera' ? 'keypad-outline' : 'qr-code-outline'}
          variant="secondary"
        />
      </View>
    </Screen>
  );
}

type Permission = ReturnType<typeof useCameraPermissions>[0];

function CameraPane({
  permission,
  onRequest,
  onBarcode,
  status,
}: {
  permission: Permission;
  onRequest: () => void;
  onBarcode: (result: { data: string }) => void;
  status: Status;
}) {
  if (!permission) {
    return (
      <View style={[styles.viewport, styles.center]}>
        <ActivityIndicator color={colors.accent} />
      </View>
    );
  }

  if (!permission.granted) {
    const message = permission.canAskAgain
      ? 'Zentty needs the camera to read the pairing QR code shown on your Mac.'
      : 'Camera access is turned off. Enable it in Settings, or enter the code by hand.';
    return (
      <View style={styles.notices}>
        <InlineNotice tone="warning" title="Camera access needed" message={message}>
          {permission.canAskAgain ? (
            <Button label="Allow camera" onPress={onRequest} icon="camera-outline" />
          ) : (
            <Button
              label="Open Settings"
              onPress={() => void Linking.openSettings()}
              icon="settings-outline"
              variant="secondary"
            />
          )}
        </InlineNotice>
      </View>
    );
  }

  return (
    <View style={styles.viewport}>
      <CameraView
        style={StyleSheet.absoluteFill}
        facing="back"
        barcodeScannerSettings={{ barcodeTypes: ['qr'] }}
        onBarcodeScanned={status.k === 'idle' ? onBarcode : undefined}
      />
      <View style={styles.overlay} pointerEvents="none">
        <View style={styles.reticle} />
        <Text style={styles.hint}>
          {status.k === 'pairing'
            ? 'Pairing…'
            : 'Point at the QR in Zentty → Settings → Mobile Devices'}
        </Text>
      </View>
      {status.k === 'pairing' ? (
        <View style={[StyleSheet.absoluteFill, styles.center, styles.scrim]}>
          <ActivityIndicator color={colors.accent} />
          <Text style={[type.dim, styles.pairingText]}>Pairing…</Text>
        </View>
      ) : null}
    </View>
  );
}

function ManualPane({
  value,
  onChange,
  onSubmit,
  status,
}: {
  value: string;
  onChange: (text: string) => void;
  onSubmit: () => void;
  status: Status;
}) {
  const pairing = status.k === 'pairing';
  return (
    <View style={styles.manual}>
      <Text style={type.dim}>
        Paste the pairing code shown beneath the QR in Zentty → Settings → Mobile Devices.
      </Text>
      <TextInput
        value={value}
        onChangeText={onChange}
        placeholder="Pairing code"
        placeholderTextColor={colors.textFaint}
        style={styles.input}
        multiline
        autoCapitalize="none"
        autoCorrect={false}
        editable={!pairing}
      />
      <Button
        label="Pair"
        onPress={onSubmit}
        icon="link-outline"
        loading={pairing}
        disabled={value.trim().length === 0}
      />
    </View>
  );
}

function errorStatus(error: unknown): Status {
  if (error instanceof PairingExpiredError) {
    return { k: 'error', tone: 'warning', title: 'Code expired', message: error.message };
  }
  if (error instanceof PairingParseError) {
    return { k: 'error', tone: 'error', title: 'Not a Zentty code', message: error.message };
  }
  if (error instanceof PairingRejectedError) {
    return {
      k: 'error',
      tone: 'error',
      title: 'Pairing rejected',
      message: `Your Mac declined the pairing (${error.reason}). Generate a fresh code and try again.`,
    };
  }
  if (error instanceof ConnectionFailedError) {
    return {
      k: 'error',
      tone: 'error',
      title: "Couldn't reach your Mac",
      message:
        'No direct or relay connection succeeded. Make sure Zentty is running and on the same network or reachable via the relay.',
    };
  }
  return {
    k: 'error',
    tone: 'error',
    title: 'Pairing failed',
    message: 'Something went wrong during pairing. Generate a fresh code and try again.',
  };
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    paddingHorizontal: space.lg,
    paddingTop: space.lg,
    paddingBottom: space.lg,
    gap: space.lg,
  },
  viewport: {
    flex: 1,
    borderRadius: radius.lg,
    overflow: 'hidden',
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
  },
  center: {
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.sm,
  },
  scrim: {
    backgroundColor: 'rgba(11,13,16,0.72)',
  },
  overlay: {
    ...StyleSheet.absoluteFill,
    alignItems: 'center',
    justifyContent: 'center',
    gap: space.xl,
  },
  reticle: {
    width: 220,
    height: 220,
    borderRadius: radius.lg,
    borderWidth: 2,
    borderColor: colors.accent,
    backgroundColor: 'transparent',
  },
  hint: {
    color: colors.text,
    fontSize: 14,
    textAlign: 'center',
    paddingHorizontal: space.xl,
    textShadowColor: 'rgba(0,0,0,0.8)',
    textShadowRadius: 6,
  },
  pairingText: {
    marginTop: space.xs,
  },
  notices: {
    flex: 1,
    justifyContent: 'center',
  },
  manual: {
    flex: 1,
    gap: space.md,
  },
  input: {
    minHeight: 120,
    borderRadius: radius.md,
    backgroundColor: colors.surface,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    padding: space.md,
    color: colors.text,
    fontSize: 14,
    textAlignVertical: 'top',
  },
});
