import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/puzzle_project.dart';

/// 本地拼圖專案儲存管理服務
///
/// 將全貌底圖、高解析局部特寫圖與 Homography 對齊參數保存在手機本地檔案系統，
/// 讓使用者分多天進行拼圖時可隨時秒開專案繼續比對。
class ProjectStorageService {
  static const String _projectsFolderName = 'puzzle_projects';
  static const String _indexFileName = 'projects_index.json';

  Future<Directory> _getProjectsRootDir() async {
    final docsDir = await getApplicationDocumentsDirectory();
    final root = Directory(p.join(docsDir.path, _projectsFolderName));
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<Directory> getProjectDirectory(String projectId) async {
    final root = await _getProjectsRootDir();
    final dir = Directory(p.join(root.path, projectId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 讀取所有已儲存的本地拼圖專案（依最後更新時間排序）
  Future<List<PuzzleProject>> loadAllProjects() async {
    try {
      final root = await _getProjectsRootDir();
      final indexFile = File(p.join(root.path, _indexFileName));
      if (!await indexFile.exists()) {
        return [];
      }
      final rawJson = await indexFile.readAsString();
      final list = jsonDecode(rawJson) as List<dynamic>;
      final projects = list
          .map((item) => PuzzleProject.fromJson(item as Map<String, dynamic>))
          .where((proj) => File(proj.overviewImagePath).existsSync())
          .toList();
      projects.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return projects;
    } catch (_) {
      return [];
    }
  }

  /// 儲存或更新單一拼圖專案
  Future<void> saveProject(PuzzleProject project) async {
    final root = await _getProjectsRootDir();
    final indexFile = File(p.join(root.path, _indexFileName));
    final existing = await loadAllProjects();
    final idx = existing.indexWhere((e) => e.id == project.id);
    if (idx >= 0) {
      existing[idx] = project;
    } else {
      existing.insert(0, project);
    }
    final encoded =
        const JsonEncoder.withIndent('  ').convert(existing.map((e) => e.toJson()).toList());
    await indexFile.writeAsString(encoded, flush: true);
  }

  /// 刪除指定拼圖專案及其所有本地影像檔
  Future<void> deleteProject(String projectId) async {
    final root = await _getProjectsRootDir();
    final projDir = Directory(p.join(root.path, projectId));
    if (await projDir.exists()) {
      await projDir.delete(recursive: true);
    }
    final existing = await loadAllProjects();
    existing.removeWhere((e) => e.id == projectId);
    final indexFile = File(p.join(root.path, _indexFileName));
    final encoded =
        const JsonEncoder.withIndent('  ').convert(existing.map((e) => e.toJson()).toList());
    await indexFile.writeAsString(encoded, flush: true);
  }
}
