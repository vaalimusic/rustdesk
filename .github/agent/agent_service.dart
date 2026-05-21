// EvertyDesk Smart Agent — injected at build time.
// Provides heartbeat, push notifications, and support requests.
// Compatible with RustDesk 1.3.5+

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class AgentService {
  AgentService._();
  static final AgentService instance = AgentService._();

  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  String? _apiServer;
  String? _serviceKey;
  String? _machineId;
  Timer? _heartbeatTimer;
  Timer? _inboxTimer;

  // Called from main() after app boots.
  Future<void> initialize({required String apiServer, String serviceKey = ''}) async {
    if (apiServer.isEmpty) return;
    _apiServer = apiServer.endsWith('/') ? apiServer.substring(0, apiServer.length - 1) : apiServer;
    _serviceKey = serviceKey;
    _machineId = await _getOrCreateMachineId();

    Future.delayed(const Duration(seconds: 5), _sendHeartbeat);
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 5), (_) => _sendHeartbeat());

    Future.delayed(const Duration(seconds: 15), _checkInbox);
    _inboxTimer = Timer.periodic(const Duration(minutes: 3), (_) => _checkInbox());
  }

  Future<String> _getOrCreateMachineId() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}agent_id');
      if (await file.exists()) {
        final id = (await file.readAsString()).trim();
        if (id.isNotEmpty) return id;
      }
      final id = _randomId();
      await file.writeAsString(id);
      return id;
    } catch (_) {
      return _randomId();
    }
  }

  String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rng = Random.secure();
    return List.generate(32, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  Future<void> _sendHeartbeat() async {
    if (_apiServer == null || _machineId == null) return;
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/heartbeat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'service_key': _serviceKey ?? '',
          'hostname': Platform.localHostname,
          'os': Platform.operatingSystem,
          'os_version': Platform.operatingSystemVersion,
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _checkInbox() async {
    if (_apiServer == null || _machineId == null) return;
    try {
      final uri = Uri.parse('$_apiServer/admin/agent/inbox').replace(queryParameters: {
        'machine_id': _machineId!,
        'service_key': _serviceKey ?? '',
      });
      final resp = await http.get(uri).timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>?) ?? [];
      for (final item in items) {
        await _ackNotification(item['id'].toString());
        _showItem(item as Map<String, dynamic>);
      }
    } catch (_) {}
  }

  Future<void> _ackNotification(String id) async {
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/notification/$id/ack?machine_id=$_machineId'),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<void> _voteNotification(String id, String vote) async {
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/notification/$id/vote?machine_id=$_machineId'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'vote': vote}),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  void _showItem(Map<String, dynamic> item) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    final id = item['id'].toString();
    final title = item['title'] as String? ?? '';
    final body = item['body'] as String? ?? '';
    final type = item['type'] as String? ?? 'banner';
    final options = (item['options'] as List<dynamic>?)?.cast<String>() ?? [];

    showDialog(
      context: ctx,
      barrierDismissible: type != 'poll',
      builder: (_) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (body.isNotEmpty) Text(body),
            if (type == 'poll' && options.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...options.map((opt) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      _voteNotification(id, opt);
                      Navigator.of(ctx).pop();
                    },
                    child: Text(opt),
                  ),
                ),
              )),
            ],
          ],
        ),
        actions: type != 'poll'
            ? [TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('OK'))]
            : [],
      ),
    );
  }

  Future<void> sendSupportRequest({String message = ''}) async {
    if (_apiServer == null || _machineId == null) return;
    try {
      await http.post(
        Uri.parse('$_apiServer/admin/agent/support-request'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'machine_id': _machineId,
          'service_key': _serviceKey ?? '',
          'hostname': Platform.localHostname,
          'message': message,
        }),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  void showSupportRequestDialog(BuildContext ctx) {
    final controller = TextEditingController();
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        title: const Text('Запросить помощь'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Опишите проблему (необязательно):'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText: 'Например: не работает принтер...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Отмена')),
          FilledButton(
            onPressed: () {
              sendSupportRequest(message: controller.text.trim());
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('Запрос отправлен. Специалист подключится в ближайшее время.')),
              );
            },
            child: const Text('Отправить'),
          ),
        ],
      ),
    );
  }
}
