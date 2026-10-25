import 'dart:io';
import 'package:flutter/material.dart';
import '../models/puzzle_project.dart';
import '../services/project_storage.dart';
import 'ar_scanner_screen.dart';
import 'project_setup_screen.dart';

/// 本地拼圖專案管理首頁
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ProjectStorageService _storage = ProjectStorageService();
  List<PuzzleProject> _projects = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProjects();
  }

  Future<void> _loadProjects() async {
    setState(() => _isLoading = true);
    final list = await _storage.loadAllProjects();
    if (!mounted) return;
    setState(() {
      _projects = list;
      _isLoading = false;
    });
  }

  Future<void> _openSetup({PuzzleProject? existingProject}) async {
    final updated = await Navigator.of(context).push<PuzzleProject>(
      MaterialPageRoute(
        builder: (_) => ProjectSetupScreen(existingProject: existingProject),
      ),
    );
    await _loadProjects();
    if (updated != null && mounted) {
      _openScanner(updated);
    }
  }

  void _openScanner(PuzzleProject project) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArScannerScreen(project: project),
      ),
    );
  }

  Future<void> _confirmDelete(PuzzleProject project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除拼圖專案'),
        content: Text('確定要刪除「${project.name}」及其儲存的參考圖片嗎？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _storage.deleteProject(project.id);
      await _loadProjects();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.extension, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Text(
              '拼圖助手 AR',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '重新整理',
            onPressed: _loadProjects,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? _buildEmptyState()
              : _buildProjectList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openSetup(),
        backgroundColor: const Color(0xFF00E676),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_a_photo),
        label: const Text(
          '新增拼圖專案',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: const Color(0xFF00E676).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.auto_awesome_mosaic,
                size: 64,
                color: Color(0xFF00E676),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              '開始你的第一副拼圖定位專案',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            const Text(
              '1. 拍攝 1 張拼圖外盒/全貌底圖（自動四點拉正）\n'
              '2. 補拍多張近距離「高解析局部特寫」解決解析度不足與反光\n'
              '3. 對準桌面散落拼圖塊，即時顯示 AR 正向箭頭 (↑) 與 Top-3 落點！',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, height: 1.6),
            ),
            const SizedBox(height: 28),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00E676),
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
              onPressed: () => _openSetup(),
              icon: const Icon(Icons.camera_alt),
              label: const Text(
                '立即建立拼圖專案',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: _projects.length,
      itemBuilder: (context, index) {
        final proj = _projects[index];
        final alignedCount =
            proj.detailTiles.where((t) => t.isAligned).length;

        return Card(
          margin: const EdgeInsets.only(bottom: 14),
          color: const Color(0xFF1A202C),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _openScanner(proj),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 160,
                  width: double.infinity,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.file(
                        File(proj.overviewImagePath),
                        fit: BoxFit.cover,
                      ),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.cyanAccent),
                          ),
                          child: Text(
                            '全貌圖 + $alignedCount 張高畫質局部圖',
                            style: const TextStyle(
                              color: Colors.cyanAccent,
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(14.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              proj.name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '底圖解析度 ${proj.overviewWidth}×${proj.overviewHeight} · 免輸入片數自動多尺度比對',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white60,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.edit_note,
                            color: Colors.white70),
                        tooltip: '管理/補拍局部高畫質圖',
                        onPressed: () => _openSetup(existingProject: proj),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Colors.redAccent),
                        tooltip: '刪除專案',
                        onPressed: () => _confirmDelete(proj),
                      ),
                      const SizedBox(width: 4),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF00E676),
                          foregroundColor: Colors.black,
                        ),
                        onPressed: () => _openScanner(proj),
                        icon: const Icon(Icons.center_focus_strong, size: 18),
                        label: const Text(
                          'AR 掃描',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
