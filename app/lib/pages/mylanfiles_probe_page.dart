import 'package:flutter/material.dart';

/// MyLanFiles P0 Spike 1 (雷区1) 探针页：
/// 验证在上游 LocalSend 代码库中"新增一个页面 + 接线入口"的最小改动面。
/// 不依赖上游 i18n（slang）与状态管理（refena），纯新文件。
class MyLanFilesProbePage extends StatefulWidget {
  const MyLanFilesProbePage({super.key});

  @override
  State<MyLanFilesProbePage> createState() => _MyLanFilesProbePageState();
}

class _MyLanFilesProbePageState extends State<MyLanFilesProbePage> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MyLanFiles Probe'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Spike 1: new page inside LocalSend fork. taps=$_taps'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () => setState(() => _taps++),
              child: const Text('tap me'),
            ),
          ],
        ),
      ),
    );
  }
}
