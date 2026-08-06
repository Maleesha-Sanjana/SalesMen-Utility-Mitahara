import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_service.dart';

typedef LocationRealtimeCallback = void Function(Map<String, dynamic> update);

class LocationRealtimeService {
  WebSocket? _socket;
  StreamSubscription? _subscription;
  Timer? _pingTimer;

  Future<void> connect({LocationRealtimeCallback? onUpdate}) async {
    await disconnect();

    final apiUri = Uri.parse(ApiService.baseUrl);
    final wsUri = Uri(
      scheme: 'ws',
      host: apiUri.host,
      port: apiUri.hasPort ? apiUri.port : 3000,
      path: '/ws',
    );

    _socket = await WebSocket.connect(wsUri.toString());
    _subscription = _socket!.listen(
      (message) {
        try {
          final payload = json.decode(message as String) as Map<String, dynamic>;
          if (payload['type'] == 'data_change' &&
              payload['dataType'] == 'location_update') {
            final data = payload['data'];
            if (data is Map<String, dynamic>) {
              onUpdate?.call(data);
            }
          }
        } catch (e) {
          print('⚠️ Realtime location message parse failed: $e');
        }
      },
      onError: (error) {
        print('⚠️ Realtime location socket error: $error');
      },
    );

    _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _socket?.add(json.encode({'type': 'ping'}));
    });
  }

  Future<void> disconnect() async {
    _pingTimer?.cancel();
    _pingTimer = null;
    await _subscription?.cancel();
    _subscription = null;
    await _socket?.close();
    _socket = null;
  }
}
