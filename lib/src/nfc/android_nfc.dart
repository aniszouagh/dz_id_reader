import 'package:flutter/services.dart';

import 'transport.dart';

/// [NfcTransport] over the plugin's Android code (DzIdReaderPlugin.kt).
class AndroidNfc implements NfcTransport {
  const AndroidNfc();

  static const _channel = MethodChannel('dz_id_reader');

  @override
  Future<NfcState> state() async =>
      switch (await _channel.invokeMethod<String>('state')) {
        'on' => NfcState.on,
        'off' => NfcState.off,
        _ => NfcState.notSupported,
      };

  @override
  Future<void> openSettings() => _channel.invokeMethod('openSettings');

  @override
  Future<void> hold(bool on) => _channel.invokeMethod('hold', on);

  @override
  Future<CardLink> connect(
      {required Duration timeout, required Duration commandTimeout}) async {
    try {
      final info = await _channel.invokeMapMethod<String, Object?>('connect', {
        'timeoutMs': timeout.inMilliseconds,
        'commandTimeoutMs': commandTimeout.inMilliseconds,
      });
      return _AndroidCard(info?['extendedLength'] == true);
    } on PlatformException catch (e) {
      throw _error(e);
    }
  }

  @override
  Future<void> cancel() => _channel.invokeMethod('cancel');

  static Exception _error(PlatformException e) => switch (e.code) {
        'timeout' => const NoCardException(),
        'cancelled' => const ConnectCancelledException(),
        'off' => const NfcUnavailableException(NfcState.off),
        'notSupported' => const NfcUnavailableException(NfcState.notSupported),
        'tagLost' => const CardLostException(lost: true),
        'io' || 'notConnected' =>
          CardLostException(lost: false, detail: e.message),
        _ => e,
      };
}

class _AndroidCard implements CardLink {
  _AndroidCard(this.extendedLength);

  @override
  final bool extendedLength;

  @override
  Future<Uint8List> transceive(Uint8List command) async {
    try {
      return (await AndroidNfc._channel
          .invokeMethod<Uint8List>('transceive', command))!;
    } on PlatformException catch (e) {
      throw AndroidNfc._error(e);
    }
  }

  @override
  Future<void> close() => AndroidNfc._channel.invokeMethod('close');
}
