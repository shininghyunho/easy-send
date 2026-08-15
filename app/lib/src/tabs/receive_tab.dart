import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../format.dart';
import '../providers.dart';

class ReceiveTab extends ConsumerWidget {
  const ReceiveTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.watch(appControllerProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const SizedBox(height: 24),
          Icon(Icons.computer,
              size: 72, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(
            controller.settings.alias,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 4),
          Text(
            '수신 대기 중 · 포트 ${controller.port}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            '지문 ${shortFingerprint(controller.identity.fingerprint)}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Text(
            '저장 폴더: ${controller.settings.saveDirPath}',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (controller.recentReceived.isNotEmpty) ...[
            const SizedBox(height: 32),
            Text('받은 파일', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final file in controller.recentReceived)
              ListTile(
                dense: true,
                leading: const Icon(Icons.download_done),
                title: Text(file.uri.pathSegments.last),
                subtitle: Text(file.parent.path,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
        ],
      ),
    );
  }
}
