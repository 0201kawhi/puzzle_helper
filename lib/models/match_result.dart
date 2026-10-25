import 'dart:ui';

/// 拼圖塊幾何邊緣類型
enum PieceEdgeType {
  /// 內部塊（四邊皆有凹凸齒）
  interior,

  /// 邊框塊（含 1 條平直邊，搜尋時自動限制於全貌圖四邊外框）
  border,

  /// 角落塊（含 2 條相鄰平直邊，搜尋時自動限制於全貌圖四個角落）
  corner,

  /// 複雜桌面保底模式（直接取準星中央圓形核心圖案，不分割外框）
  coreFallback,
}

extension PieceEdgeTypeLabel on PieceEdgeType {
  String get displayName {
    switch (this) {
      case PieceEdgeType.interior:
        return '內部拼圖塊';
      case PieceEdgeType.border:
        return '直邊外框塊';
      case PieceEdgeType.corner:
        return '角落雙直邊塊';
      case PieceEdgeType.coreFallback:
        return '準星核心取樣';
    }
  }
}

/// 鏡頭畫面中偵測到的單塊拼圖資訊
class DetectedPiece {
  final int id;

  /// 在相機畫面中的正規化邊界框 (0.0 ~ 1.0)
  final Rect boundingBoxNormalized;

  /// 在相機畫面中的正規化中心座標 (0.0 ~ 1.0)
  final Offset centerNormalized;

  /// 拼圖輪廓多邊形頂點（正規化 0.0 ~ 1.0），供 AR 畫面描繪外框
  final List<Offset> contourPointsNormalized;

  /// 最小外接矩形 (minAreaRect) 的主軸旋轉角（度，-90 ~ 90）
  final double principalAngleDeg;

  /// 拼圖邊緣幾何分類（內部塊 / 直邊外框塊 / 角落塊 / 核心保底）
  final PieceEdgeType edgeType;

  /// 若為直邊或角落塊，記錄直邊朝外法線在相機座標系中的角度（度）
  final List<double> flatEdgeNormalAnglesDeg;

  /// 是否為目前鎖定比對的目標拼圖塊
  final bool isLockedTarget;

  const DetectedPiece({
    required this.id,
    required this.boundingBoxNormalized,
    required this.centerNormalized,
    required this.contourPointsNormalized,
    required this.principalAngleDeg,
    required this.edgeType,
    this.flatEdgeNormalAnglesDeg = const [],
    this.isLockedTarget = false,
  });

  DetectedPiece copyWith({bool? isLockedTarget}) {
    return DetectedPiece(
      id: id,
      boundingBoxNormalized: boundingBoxNormalized,
      centerNormalized: centerNormalized,
      contourPointsNormalized: contourPointsNormalized,
      principalAngleDeg: principalAngleDeg,
      edgeType: edgeType,
      flatEdgeNormalAnglesDeg: flatEdgeNormalAnglesDeg,
      isLockedTarget: isLockedTarget ?? this.isLockedTarget,
    );
  }
}

/// 原圖上的單一候選落點（Top-3 候選結果）
class CandidateLocation {
  /// 排名 (1, 2, 3)
  final int rank;

  /// 在全貌底圖 (Overview) 上的正規化中心座標 (0.0 ~ 1.0)
  final Offset overviewCenterNormalized;

  /// 在全貌底圖上的正規化尺寸 (寬, 高 0.0 ~ 1.0)
  final Size overviewSizeNormalized;

  /// 正確擺放方向指示角（度，0°~360°）：
  /// 代表「原圖的正上方 (↑)」對應在目前鏡頭畫面中拼圖塊上的哪個方向，
  /// AR 介面會直接依此角度在拼圖塊上畫出「正向箭頭 (↑)」。
  final double upArrowAngleInCameraDeg;

  /// 使用者需將手中拼圖順時針旋轉幾度才能擺正（例如 +90°、180°、-90°）
  final double requiredClockwiseRotationDeg;

  /// 比對信心度 (0.0 ~ 1.0)
  final double confidence;

  /// 命中所使用的引擎名稱（如 'AKAZE 特徵引擎' 或 '多尺度色彩/結構模板'）
  final String engineUsed;

  /// 命中的局部特寫圖 ID（若直接命中全貌底圖則為 null）
  final String? matchedTileId;

  /// 命中的參考圖名稱（如 '局部特寫 #2' 或 '全貌底圖'）
  final String matchedTileLabel;

  const CandidateLocation({
    required this.rank,
    required this.overviewCenterNormalized,
    required this.overviewSizeNormalized,
    required this.upArrowAngleInCameraDeg,
    required this.requiredClockwiseRotationDeg,
    required this.confidence,
    required this.engineUsed,
    this.matchedTileId,
    required this.matchedTileLabel,
  });

  /// 轉換為全貌底圖上的正規化矩形區域
  Rect get overviewRectNormalized => Rect.fromCenter(
        center: overviewCenterNormalized,
        width: overviewSizeNormalized.width.clamp(0.02, 0.35),
        height: overviewSizeNormalized.height.clamp(0.02, 0.35),
      );
}

/// 單幀即時 AR 視覺分析結果
class FrameAnalysisResult {
  /// 畫面中偵測到的所有拼圖塊
  final List<DetectedPiece> detectedPieces;

  /// 目前鎖定比對的拼圖塊 ID
  final int? activePieceId;

  /// 鎖定拼圖塊的 Top-3 候選落點
  final List<CandidateLocation> candidates;

  /// 單幀視覺處理耗時（毫秒）
  final int processingTimeMs;

  const FrameAnalysisResult({
    required this.detectedPieces,
    this.activePieceId,
    required this.candidates,
    required this.processingTimeMs,
  });

  DetectedPiece? get activePiece {
    if (activePieceId == null) return null;
    for (final p in detectedPieces) {
      if (p.id == activePieceId) return p;
    }
    return detectedPieces.isNotEmpty ? detectedPieces.first : null;
  }

  static const empty = FrameAnalysisResult(
    detectedPieces: [],
    activePieceId: null,
    candidates: [],
    processingTimeMs: 0,
  );
}
