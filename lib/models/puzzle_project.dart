import 'dart:ui';

/// 單張高解析度局部特寫參考圖 (Detail Tile)
///
/// 透過特徵點匹配計算出 [homographyToOverview] (3x3 單應性矩陣)，
/// 將局部特寫圖上的任意像素座標 (x_tile, y_tile) 精確投射回全貌底圖 (Overview) 座標。
class DetailTile {
  final String id;
  final String label;
  final String imagePath;
  final int width;
  final int height;

  /// 3x3 Homography 矩陣 (Row-major 9 個浮點數)：
  /// 將局部圖像素座標 (x, y) 轉換為全貌底圖像素座標 (u, v)。
  final List<double>? homographyToOverview;

  /// 局部圖投射在全貌底圖上的正規化邊界框 (0.0 ~ 1.0)，用於 UI 顯示高畫質覆蓋範圍。
  final Rect? coverageRectNormalized;

  /// 對齊至全貌底圖時的 RANSAC 特徵內點數 (Inliers)
  final int inlierCount;

  const DetailTile({
    required this.id,
    required this.label,
    required this.imagePath,
    required this.width,
    required this.height,
    this.homographyToOverview,
    this.coverageRectNormalized,
    this.inlierCount = 0,
  });

  bool get isAligned =>
      homographyToOverview != null && homographyToOverview!.length == 9;

  /// 將局部圖上的像素點 (tileX, tileY) 透過單應性矩陣投射至全貌底圖像素座標
  Offset? projectToOverviewPixel(double tileX, double tileY) {
    final h = homographyToOverview;
    if (h == null || h.length != 9) return null;
    final denom = h[6] * tileX + h[7] * tileY + h[8];
    if (denom.abs() < 1e-9) return null;
    final u = (h[0] * tileX + h[1] * tileY + h[2]) / denom;
    final v = (h[3] * tileX + h[4] * tileY + h[5]) / denom;
    return Offset(u, v);
  }

  /// 計算局部圖相對於全貌底圖的基準旋轉角度（度）
  double get relativeRotationDeg {
    final p0 = projectToOverviewPixel(width * 0.5, height * 0.5);
    final pRight = projectToOverviewPixel(width * 0.5 + 50.0, height * 0.5);
    if (p0 == null || pRight == null) return 0.0;
    final dx = pRight.dx - p0.dx;
    final dy = pRight.dy - p0.dy;
    return Offset(dx, dy).direction * 180.0 / 3.141592653589793;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'imagePath': imagePath,
        'width': width,
        'height': height,
        'homographyToOverview': homographyToOverview,
        'coverageRectNormalized': coverageRectNormalized == null
            ? null
            : {
                'left': coverageRectNormalized!.left,
                'top': coverageRectNormalized!.top,
                'right': coverageRectNormalized!.right,
                'bottom': coverageRectNormalized!.bottom,
              },
        'inlierCount': inlierCount,
      };

  factory DetailTile.fromJson(Map<String, dynamic> json) {
    final rectMap = json['coverageRectNormalized'] as Map<String, dynamic>?;
    final hList = (json['homographyToOverview'] as List<dynamic>?)
        ?.map((e) => (e as num).toDouble())
        .toList();

    return DetailTile(
      id: json['id'] as String,
      label: json['label'] as String,
      imagePath: json['imagePath'] as String,
      width: (json['width'] as num).toInt(),
      height: (json['height'] as num).toInt(),
      homographyToOverview: hList,
      coverageRectNormalized: rectMap == null
          ? null
          : Rect.fromLTRB(
              (rectMap['left'] as num).toDouble(),
              (rectMap['top'] as num).toDouble(),
              (rectMap['right'] as num).toDouble(),
              (rectMap['bottom'] as num).toDouble(),
            ),
      inlierCount: (json['inlierCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 拼圖專案資料模型（基礎本地儲存）
///
/// 包含 1 張透視拉正後的「全貌底圖」與任意張「高解析度局部特寫圖」。
class PuzzleProject {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String overviewImagePath;
  final int overviewWidth;
  final int overviewHeight;
  final List<DetailTile> detailTiles;

  const PuzzleProject({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    required this.overviewImagePath,
    required this.overviewWidth,
    required this.overviewHeight,
    this.detailTiles = const [],
  });

  PuzzleProject copyWith({
    String? name,
    DateTime? updatedAt,
    String? overviewImagePath,
    int? overviewWidth,
    int? overviewHeight,
    List<DetailTile>? detailTiles,
  }) {
    return PuzzleProject(
      id: id,
      name: name ?? this.name,
      createdAt: createdAt,
      updatedAt: updatedAt ?? DateTime.now(),
      overviewImagePath: overviewImagePath ?? this.overviewImagePath,
      overviewWidth: overviewWidth ?? this.overviewWidth,
      overviewHeight: overviewHeight ?? this.overviewHeight,
      detailTiles: detailTiles ?? this.detailTiles,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'overviewImagePath': overviewImagePath,
        'overviewWidth': overviewWidth,
        'overviewHeight': overviewHeight,
        'detailTiles': detailTiles.map((t) => t.toJson()).toList(),
      };

  factory PuzzleProject.fromJson(Map<String, dynamic> json) {
    return PuzzleProject(
      id: json['id'] as String,
      name: json['name'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      overviewImagePath: json['overviewImagePath'] as String,
      overviewWidth: (json['overviewWidth'] as num).toInt(),
      overviewHeight: (json['overviewHeight'] as num).toInt(),
      detailTiles: (json['detailTiles'] as List<dynamic>? ?? [])
          .map((e) => DetailTile.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}
