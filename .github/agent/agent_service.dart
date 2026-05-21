// EvertyDesk Smart Agent — injected at build time.
// Provides heartbeat, push notifications, and support requests.
// Compatible with RustDesk 1.3.5+

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
        if (item['type'] == 'config_update') {
          _withContext((ctx) async {
            await _ackNotification(item['id'].toString());
            _applyConfigUpdate(item as Map<String, dynamic>);
          });
        } else {
          _withContext((ctx) async {
            await _ackNotification(item['id'].toString());
            _showItemWithCtx(ctx, item as Map<String, dynamic>);
          });
        }
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

  Future<void> _applyConfigUpdate(Map<String, dynamic> item) async {
    try {
      final body = jsonDecode(item['body'] as String? ?? '{}') as Map<String, dynamic>;
      final server = (body['server'] as String?) ?? '';
      final key = (body['key'] as String?) ?? '';
      final apiServer = (body['api_server'] as String?) ?? '';
      _showConfigUpdateDialog(server: server, key: key, apiServer: apiServer);
    } catch (_) {}
  }

  void _showConfigUpdateDialog({required String server, required String key, required String apiServer}) {
    _withContext((ctx) => _showConfigUpdateDialogWithCtx(ctx, server: server, key: key, apiServer: apiServer));
  }

  void _showConfigUpdateDialogWithCtx(BuildContext ctx, {required String server, required String key, required String apiServer}) {
    final lines = <Widget>[];
    if (server.isNotEmpty) lines.add(_configRow('ID/Relay сервер', server));
    if (key.isNotEmpty) lines.add(_configRow('Публичный ключ', key));
    if (apiServer.isNotEmpty) lines.add(_configRow('API сервер', apiServer));
    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Обновление настроек подключения'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Администратор обновил настройки сервера. Скопируйте значения и вставьте их в Настройки → Сеть.'),
              const SizedBox(height: 12),
              ...lines,
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _configRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
              IconButton(
                icon: const Icon(Icons.copy, size: 18),
                tooltip: 'Копировать',
                onPressed: () => Clipboard.setData(ClipboardData(text: value)),
              ),
            ],
          ),
        ],
      ),
    );
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

  BuildContext? _findContext() {
    final ctx = navigatorKey.currentContext;
    if (ctx != null) return ctx;
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    BuildContext? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget is Navigator) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }
    visit(root);
    return found;
  }

  void _withContext(void Function(BuildContext ctx) action, {int retries = 30}) {
    final ctx = _findContext();
    if (ctx != null) {
      action(ctx);
      return;
    }
    if (retries <= 0) return;
    Future.delayed(const Duration(seconds: 2), () => _withContext(action, retries: retries - 1));
  }

  void _showItem(Map<String, dynamic> item) {
    _withContext((ctx) => _showItemWithCtx(ctx, item));
  }

  void _showItemWithCtx(BuildContext ctx, Map<String, dynamic> item) {
    final id = item['id'].toString();
    final title = item['title'] as String? ?? '';
    final body = item['body'] as String? ?? '';
    final type = item['type'] as String? ?? 'banner';
    final options = (item['options'] as List<dynamic>?)?.cast<String>() ?? [];
    final link = (item['link'] as String?) ?? '';
    final linkLabel = (item['link_label'] as String?) ?? '';
    final imageUrl = (item['image_url'] as String?) ?? '';
    final severity = (item['severity'] as String?) ?? 'info';

    final accent = _severityColor(severity);
    final accentIcon = _severityIcon(severity);

    showDialog(
      context: ctx,
      barrierDismissible: type != 'poll',
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
        titlePadding: EdgeInsets.zero,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imageUrl.isNotEmpty)
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                child: Image.network(
                  imageUrl,
                  height: 140,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 6),
              child: Row(
                children: [
                  if (type == 'banner') Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Icon(accentIcon, color: accent, size: 24),
                  ),
                  Expanded(
                    child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (body.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Text(body, style: const TextStyle(fontSize: 14, height: 1.45)),
                ),
              if (type == 'poll' && options.isNotEmpty) ...[
                const SizedBox(height: 12),
                ...options.map((opt) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
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
        ),
        actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 8),
        actions: type == 'poll'
            ? []
            : [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Закрыть'),
                ),
                if (link.isNotEmpty)
                  FilledButton.icon(
                    onPressed: () {
                      _openExternalLink(link);
                      Navigator.of(ctx).pop();
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text(linkLabel.isNotEmpty ? linkLabel : 'Открыть'),
                  ),
              ],
      ),
    );
  }

  Color _severityColor(String severity) {
    switch (severity) {
      case 'success': return const Color(0xFF16A34A);
      case 'warning': return const Color(0xFFEA580C);
      case 'error':   return const Color(0xFFDC2626);
      default:        return const Color(0xFF2563EB);
    }
  }

  IconData _severityIcon(String severity) {
    switch (severity) {
      case 'success': return Icons.check_circle_rounded;
      case 'warning': return Icons.warning_amber_rounded;
      case 'error':   return Icons.error_rounded;
      default:        return Icons.info_rounded;
    }
  }

  Future<void> _openExternalLink(String url) async {
    try {
      // Copy to clipboard as a robust fallback (Windows: opens via shell, anywhere: user can paste)
      await Clipboard.setData(ClipboardData(text: url));
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url], runInShell: true);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [url]);
      }
    } catch (_) {}
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
