import 'package:easy_send_core/easy_send_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../format.dart';
import '../providers.dart';

class SettingsTab extends ConsumerStatefulWidget {
  const SettingsTab({super.key});

  @override
  ConsumerState<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends ConsumerState<SettingsTab> {
  late final TextEditingController _alias;
  final _manualAddress = TextEditingController();
  bool _addingManual = false;

  @override
  void initState() {
    super.initState();
    _alias = TextEditingController(
        text: ref.read(appControllerProvider).settings.alias);
  }

  @override
  void dispose() {
    _alias.dispose();
    _manualAddress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('내 기기', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _alias,
                  decoration: const InputDecoration(
                    labelText: '기기 이름 (alias)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _applyAlias(controller.settings.alias),
                child: const Text('적용'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('저장 폴더'),
            subtitle: Text(controller.settings.saveDirPath),
            trailing: OutlinedButton(
              onPressed: _pickSaveDir,
              child: const Text('변경'),
            ),
          ),
          const Divider(height: 32),
          Text('IP 직접 입력', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            '멀티캐스트가 막힌 네트워크에서 상대 기기를 목록에 추가합니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _manualAddress,
                  decoration: const InputDecoration(
                    labelText: '192.168.0.10 또는 192.168.0.10:53318',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _addingManual ? null : _addManualDevice,
                child: _addingManual
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('추가'),
              ),
            ],
          ),
          const Divider(height: 32),
          Text('신뢰 기기', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (controller.trustStore.all.isEmpty)
            Text('아직 없습니다. 첫 전송을 승인하면 여기에 저장됩니다.',
                style: Theme.of(context).textTheme.bodySmall),
          for (final device in controller.trustStore.all)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.verified_user_outlined),
              title: Text(device.alias),
              subtitle: Text(
                  '${shortFingerprint(device.fingerprint)} · 최초 승인 '
                  '${device.firstApprovedAt.toLocal().toString().substring(0, 16)}'),
              trailing: IconButton(
                tooltip: '신뢰 해제',
                icon: const Icon(Icons.delete_outline),
                onPressed: () =>
                    controller.removeTrusted(device.fingerprint),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _applyAlias(String current) async {
    final alias = _alias.text.trim();
    if (alias.isEmpty || alias == current) return;
    final controller = ref.read(appControllerProvider);
    await controller
        .applySettings(controller.settings.copyWith(alias: alias));
    _toast('기기 이름을 적용했습니다');
  }

  Future<void> _pickSaveDir() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (path == null) return;
    final controller = ref.read(appControllerProvider);
    await controller
        .applySettings(controller.settings.copyWith(saveDirPath: path));
    _toast('저장 폴더를 변경했습니다');
  }

  Future<void> _addManualDevice() async {
    final input = _manualAddress.text.trim();
    if (input.isEmpty) return;
    final parts = input.split(':');
    final address = parts[0];
    final port = parts.length > 1
        ? int.tryParse(parts[1])
        : Protocol.defaultServicePort;
    if (address.isEmpty || port == null) {
      _toast('주소 형식이 잘못되었습니다');
      return;
    }
    setState(() => _addingManual = true);
    final controller = ref.read(appControllerProvider);
    try {
      final device = await exchangeInfo(
        address: address,
        port: port,
        self: controller.self,
      ).timeout(const Duration(seconds: 10));
      controller.addManualDevice(device);
      _manualAddress.clear();
      _toast('${device.info.alias} 추가됨 — 보내기 탭에서 확인하세요');
    } on FingerprintMismatchException {
      _toast('기기 지문이 응답과 다릅니다 — 추가하지 않았습니다');
    } catch (_) {
      _toast('연결 실패 — 주소와 상대 앱 실행 여부를 확인하세요');
    } finally {
      if (mounted) setState(() => _addingManual = false);
    }
  }

  void _toast(String message) {
    if (mounted == false) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
