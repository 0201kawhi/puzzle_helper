import 'dart:math' as math;
import 'dart:ui';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../../models/match_result.dart';
import '../../models/puzzle_project.dart';
import 'piece_segmenter.dart';
import 'reference_mapper.dart';

/// 單張已建立索引的參考圖（可為全貌底圖或高解析局部特寫圖）
class _IndexedReferenceTarget {
  final String? tileId;
  final String label;
  final int originalWidth;
  final int originalHeight;
  final DetailTile? detailTile;

  /// AKAZE 特徵點與描述子（用於階段一：高速特徵比對）
  final cv.VecKeyPoint keypoints;
  final cv.Mat descriptors;

  /// 供階段二模板比對使用的正規化 LAB 影像與 Sobel 梯度圖
  final cv.Mat templateLab;
  final cv.Mat templateGrad;
  final double templateScaleFromOriginal;

  _IndexedReferenceTarget({
    required this.tileId,
    required this.label,
    required this.originalWidth,
    required this.originalHeight,
    required this.detailTile,
    required this.keypoints,
    required this.descriptors,
    required this.templateLab,
    required this.templateGrad,
    required this.templateScaleFromOriginal,
  });

  void dispose() {
    keypoints.dispose();
    descriptors.dispose();
    templateLab.dispose();
    templateGrad.dispose();
  }
}

/// 拼圖混合雙引擎比對器
///
/// 結合：
/// 1. 智慧抗色偏前處理 (LAB + CLAHE + Sobel 邊緣梯度)
/// 2. 階段一：旋轉/尺度不變特徵點匹配 (AKAZE + RANSAC Homography)
/// 3. 階段二：多尺度金字塔 (6 個尺度) + 四向正交角 (0°/90°/180°/270°) 遮罩模板比對
/// 4. 直邊/角落幾何約束：若偵測到直邊外框塊，自動鎖定方向並僅搜尋原圖四邊外框！
class PuzzleMatcher {
  final PuzzleProject project;
  _IndexedReferenceTarget? _overviewTarget;
  final List<_IndexedReferenceTarget> _detailTargets = [];
  bool _isInitialized = false;

  /// 多尺度搜尋比例（代表單塊拼圖佔全貌圖寬度的比例，涵蓋約 100 片至 1500 片各種規格與拍攝距離）
  static const List<double> _multiScaleWidthRatios = [
    1.0 / 14.0,
    1.0 / 18.0,
    1.0 / 23.0,
    1.0 / 29.0,
    1.0 / 36.0,
    1.0 / 44.0,
  ];

  PuzzleMatcher(this.project);

  bool get isInitialized => _isInitialized;

  /// 初始化專案參考圖索引（全貌底圖 + 所有已對齊的高解析局部圖）
  void initializeIndex() {
    dispose();
    final akaze = cv.AKAZE.create();
    try {
      // 1. 建立全貌底圖索引
      _overviewTarget = _buildTargetIndex(
        imagePath: project.overviewImagePath,
        tileId: null,
        label: '全貌底圖',
        detailTile: null,
        akaze: akaze,
        targetTemplateMaxDim: 960,
      );

      // 2. 建立所有已對齊的高解析局部特寫圖索引
      for (final tile in project.detailTiles) {
        if (!tile.isAligned) continue;
        final indexed = _buildTargetIndex(
          imagePath: tile.imagePath,
          tileId: tile.id,
          label: tile.label,
          detailTile: tile,
          akaze: akaze,
          targetTemplateMaxDim: 800,
        );
        if (indexed != null) {
          _detailTargets.add(indexed);
        }
      }

      _isInitialized = _overviewTarget != null;
    } finally {
      akaze.dispose();
    }
  }

  _IndexedReferenceTarget? _buildTargetIndex({
    required String imagePath,
    required String? tileId,
    required String label,
    required DetailTile? detailTile,
    required cv.AKAZE akaze,
    required int targetTemplateMaxDim,
  }) {
    final raw = cv.imread(imagePath);
    if (raw.isEmpty) {
      raw.dispose();
      return null;
    }

    try {
      final int origW = raw.cols;
      final int origH = raw.rows;
      final norm = ReferenceMapper.normalizeIlluminationAndColor(raw);

      // 提取高解析度 AKAZE 特徵
      final (kp, desc) =
          akaze.detectAndCompute(norm.claheGray, cv.Mat.empty());

      // 建立供多尺度模板比對使用的適中解析度 LAB 與 Sobel 梯度圖
      final double maxDim = math.max(origW, origH).toDouble();
      final double tmplScale =
          maxDim > targetTemplateMaxDim ? targetTemplateMaxDim / maxDim : 1.0;
      final int tmplW = math.max(64, (origW * tmplScale).round());
      final int tmplH = math.max(64, (origH * tmplScale).round());

      final resizedLab = tmplScale < 0.999
          ? cv.resize(norm.labImage, (tmplW, tmplH))
          : norm.labImage.clone();
      final resizedGray = tmplScale < 0.999
          ? cv.resize(norm.claheGray, (tmplW, tmplH))
          : norm.claheGray.clone();
      final grad = ReferenceMapper.computeGradientMagnitude(resizedGray);
      resizedGray.dispose();

      norm.normalizedBgr.dispose();
      norm.claheGray.dispose();
      norm.labImage.dispose();

      return _IndexedReferenceTarget(
        tileId: tileId,
        label: label,
        originalWidth: origW,
        originalHeight: origH,
        detailTile: detailTile,
        keypoints: kp,
        descriptors: desc,
        templateLab: resizedLab,
        templateGrad: grad,
        templateScaleFromOriginal: tmplScale,
      );
    } finally {
      raw.dispose();
    }
  }

  /// 對分割出的目標拼圖塊執行雙引擎比對，回傳 Top-3 候選落點
  List<CandidateLocation> matchPiece(SegmentedTargetPatch targetPatch) {
    if (!_isInitialized || _overviewTarget == null) return const [];

    final rawCandidates = <CandidateLocation>[];

    // 前處理目標拼圖塊：LAB + CLAHE 光影色差正規化 + Sobel 邊緣梯度
    final normPiece =
        ReferenceMapper.normalizeIlluminationAndColor(targetPatch.croppedBgr);
    final pieceGrad =
        ReferenceMapper.computeGradientMagnitude(normPiece.claheGray);

    try {
      // =======================================================================
      // 階段一：旋轉與尺度不變特徵點匹配 (優先比對所有高解析局部特寫圖，再比對全貌圖)
      // =======================================================================
      final allTargets = <_IndexedReferenceTarget>[
        ..._detailTargets,
        _overviewTarget!,
      ];

      final featureMatches = _matchByFeatures(
        pieceGray: normPiece.claheGray,
        erodedMask: targetPatch.erodedMask,
        targets: allTargets,
      );
      rawCandidates.addAll(featureMatches);

      // =======================================================================
      // 階段二：若特徵點匹配未滿 3 個高信心候選（如天空、水面、漸層色塊），
      // 啟動「多尺度金字塔 + 幾何四向正交角 (0°/90°/180°/270°) + 直邊外框約束」模板比對
      // =======================================================================
      final bool hasStrongFeatureMatch = rawCandidates.isNotEmpty &&
          rawCandidates.first.confidence >= 0.78;

      if (!hasStrongFeatureMatch || rawCandidates.length < 3) {
        final templateMatches = _matchByMultiScaleTemplate(
          pieceLab: normPiece.labImage,
          pieceGrad: pieceGrad,
          erodedMask: targetPatch.erodedMask,
          pieceInfo: targetPatch.pieceInfo,
          overviewTarget: _overviewTarget!,
        );
        rawCandidates.addAll(templateMatches);
      }

      // 依信心度排序並執行非極大值抑制 (NMS)，確保 Top-3 為不同落點
      return _selectTop3DistinctCandidates(rawCandidates);
    } finally {
      normPiece.normalizedBgr.dispose();
      normPiece.claheGray.dispose();
      normPiece.labImage.dispose();
      pieceGrad.dispose();
    }
  }

  /// 階段一：AKAZE 特徵點 + RANSAC Homography 幾何驗證
  List<CandidateLocation> _matchByFeatures({
    required cv.Mat pieceGray,
    required cv.Mat erodedMask,
    required List<_IndexedReferenceTarget> targets,
  }) {
    final results = <CandidateLocation>[];
    final akaze = cv.AKAZE.create();
    final matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);

    try {
      final (kpPiece, descPiece) =
          akaze.detectAndCompute(pieceGray, erodedMask);
      if (descPiece.isEmpty || kpPiece.length < 6) {
        kpPiece.dispose();
        descPiece.dispose();
        return results;
      }

      final double pieceCx = pieceGray.cols * 0.5;
      final double pieceCy = pieceGray.rows * 0.5;

      for (final target in targets) {
        if (target.descriptors.isEmpty || target.keypoints.length < 8) continue;

        final knn = matcher.knnMatch(descPiece, target.descriptors, 2);
        final srcPts = <cv.Point2f>[];
        final dstPts = <cv.Point2f>[];

        for (int i = 0; i < knn.length; i++) {
          final pair = knn[i];
          if (pair.length >= 2) {
            final m = pair[0];
            final n = pair[1];
            if (m.distance < 0.78 * n.distance) {
              srcPts.add(kpPiece[m.queryIdx].pt);
              dstPts.add(target.keypoints[m.trainIdx].pt);
            }
          }
        }
        knn.dispose();

        if (srcPts.length < 6) continue;

        final srcVec = cv.VecPoint2f.fromList(srcPts);
        final dstVec = cv.VecPoint2f.fromList(dstPts);
        final srcMat = cv.Mat.fromVec(srcVec);
        final dstMat = cv.Mat.fromVec(dstVec);
        final inlierMask = cv.Mat.empty();

        final hMat = cv.findHomography(
          srcMat,
          dstMat,
          method: cv.RANSAC,
          ransacReprojThreshold: 4.5,
          mask: inlierMask,
        );

        if (!hMat.isEmpty && hMat.rows == 3 && hMat.cols == 3) {
          final int inliers = cv.countNonZero(inlierMask);
          if (inliers >= 5) {
            final h = <double>[
              hMat.at<double>(0, 0),
              hMat.at<double>(0, 1),
              hMat.at<double>(0, 2),
              hMat.at<double>(1, 0),
              hMat.at<double>(1, 1),
              hMat.at<double>(1, 2),
              hMat.at<double>(2, 0),
              hMat.at<double>(2, 1),
              hMat.at<double>(2, 2),
            ];

            final centerOnTarget = _projectPoint(h, pieceCx, pieceCy);
            final rightOnTarget = _projectPoint(h, pieceCx + 25.0, pieceCy);
            final topOnTarget = _projectPoint(h, pieceCx, pieceCy - 25.0);

            if (centerOnTarget != null &&
                rightOnTarget != null &&
                topOnTarget != null) {
              // 若命中局部特寫圖，透過該局部圖的 Homography 投射回全貌底圖座標
              Offset? centerOnOverviewPx;
              Offset? rightOnOverviewPx;

              if (target.detailTile != null) {
                centerOnOverviewPx = target.detailTile!.projectToOverviewPixel(
                  centerOnTarget.dx,
                  centerOnTarget.dy,
                );
                rightOnOverviewPx = target.detailTile!.projectToOverviewPixel(
                  rightOnTarget.dx,
                  rightOnTarget.dy,
                );
              } else {
                centerOnOverviewPx = centerOnTarget;
                rightOnOverviewPx = rightOnTarget;
              }

              final int ovW = _overviewTarget!.originalWidth;
              final int ovH = _overviewTarget!.originalHeight;

              if (centerOnOverviewPx != null && rightOnOverviewPx != null) {
                final double normX = centerOnOverviewPx.dx / ovW;
                final double normY = centerOnOverviewPx.dy / ovH;

                if (normX >= 0.0 &&
                    normX <= 1.0 &&
                    normY >= 0.0 &&
                    normY <= 1.0) {
                  final double scalePx =
                      (rightOnOverviewPx - centerOnOverviewPx).distance / 25.0;
                  final double estW =
                      (pieceGray.cols * scalePx / ovW).clamp(0.025, 0.25);
                  final double estH =
                      (pieceGray.rows * scalePx / ovH).clamp(0.025, 0.25);

                  // 計算拼圖塊在相機中相對於全貌圖的旋轉角
                  final double dx = rightOnOverviewPx.dx - centerOnOverviewPx.dx;
                  final double dy = rightOnOverviewPx.dy - centerOnOverviewPx.dy;
                  final double pieceRightInOverviewDeg =
                      math.atan2(dy, dx) * 180.0 / math.pi;

                  // 使用者需順時針旋轉的角度 = -pieceRightInOverviewDeg
                  final double cwRotDeg = _normalizeAngleDeg(-pieceRightInOverviewDeg);
                  // 原圖正上方 (-90°) 在相機畫面中的方向角
                  final double upArrowDeg =
                      _normalizeAngleDeg(-90.0 - pieceRightInOverviewDeg);

                  final double conf =
                      (0.55 + (inliers / 22.0) * 0.43).clamp(0.55, 0.99);

                  results.add(
                    CandidateLocation(
                      rank: 1,
                      overviewCenterNormalized: Offset(normX, normY),
                      overviewSizeNormalized: Size(estW, estH),
                      upArrowAngleInCameraDeg: upArrowDeg,
                      requiredClockwiseRotationDeg: cwRotDeg,
                      confidence: conf,
                      engineUsed: 'AKAZE 特徵引擎 ($inliers 內點)',
                      matchedTileId: target.tileId,
                      matchedTileLabel: target.label,
                    ),
                  );
                }
              }
            }
          }
        }

        srcVec.dispose();
        dstVec.dispose();
        srcMat.dispose();
        dstMat.dispose();
        inlierMask.dispose();
        hMat.dispose();
      }

      kpPiece.dispose();
      descPiece.dispose();
    } finally {
      akaze.dispose();
      matcher.dispose();
    }

    return results;
  }

  /// 階段二：多尺度金字塔 (6 尺度) + 四向正交角 (0°/90°/180°/270°) + 直邊外框約束模板匹配
  List<CandidateLocation> _matchByMultiScaleTemplate({
    required cv.Mat pieceLab,
    required cv.Mat pieceGrad,
    required cv.Mat erodedMask,
    required DetectedPiece pieceInfo,
    required _IndexedReferenceTarget overviewTarget,
  }) {
    final candidates = <CandidateLocation>[];
    final int refW = overviewTarget.templateLab.cols;
    final int refH = overviewTarget.templateLab.rows;

    // 1. 先將拼圖塊依 minAreaRect 的主軸角度轉正，使拼圖四邊對齊正交座標軸
    final baseAlignedLab =
        _rotateMatKeepSize(pieceLab, -pieceInfo.principalAngleDeg, borderVal: 128);
    final baseAlignedGrad =
        _rotateMatKeepSize(pieceGrad, -pieceInfo.principalAngleDeg, borderVal: 0);
    final baseAlignedMask =
        _rotateMatKeepSize(erodedMask, -pieceInfo.principalAngleDeg, borderVal: 0);

    try {
      // 測試 4 個正交方向 (0°, 90°, 180°, 270°)
      const orthoAngles = [0, 90, 180, 270];

      for (final orthoDeg in orthoAngles) {
        final double totalPieceClockwiseRotDeg =
            _normalizeAngleDeg(orthoDeg - pieceInfo.principalAngleDeg);

        // 若為直邊塊或角落塊，根據直邊旋轉後的朝向，決定在原圖上允許搜尋的區域 (Search ROI)
        final allowedSearchRois = _computeAllowedSearchRois(
          edgeType: pieceInfo.edgeType,
          flatNormalsInCameraDeg: pieceInfo.flatEdgeNormalAnglesDeg,
          appliedClockwiseRotDeg: totalPieceClockwiseRotDeg,
          refW: refW,
          refH: refH,
        );
        if (allowedSearchRois.isEmpty) continue;

        final rotLab = _rotateOrthogonal(baseAlignedLab, orthoDeg);
        final rotGrad = _rotateOrthogonal(baseAlignedGrad, orthoDeg);
        final rotMask = _rotateOrthogonal(baseAlignedMask, orthoDeg);

        final double aspect =
            rotLab.rows / math.max(1.0, rotLab.cols.toDouble());

        // 在多尺度金字塔下搜尋（免手動輸入片數或比例校準）
        for (final widthRatio in _multiScaleWidthRatios) {
          final int targetPatchW = (refW * widthRatio).round();
          final int targetPatchH = (targetPatchW * aspect).round();

          if (targetPatchW < 14 ||
              targetPatchH < 14 ||
              targetPatchW >= refW - 4 ||
              targetPatchH >= refH - 4) {
            continue;
          }

          final scaledLab = cv.resize(rotLab, (targetPatchW, targetPatchH));
          final scaledGrad = cv.resize(rotGrad, (targetPatchW, targetPatchH));
          final scaledMask = cv.resize(
            rotMask,
            (targetPatchW, targetPatchH),
            interpolation: cv.INTER_NEAREST,
          );

          for (final searchRoi in allowedSearchRois) {
            if (searchRoi.width <= targetPatchW + 2 ||
                searchRoi.height <= targetPatchH + 2) {
              continue;
            }

            final refLabRegion = overviewTarget.templateLab.region(searchRoi);
            final refGradRegion = overviewTarget.templateGrad.region(searchRoi);

            // 結合 LAB 色彩模板匹配與 Sobel 結構梯度模板匹配
            final resLab = cv.matchTemplate(
              refLabRegion,
              scaledLab,
              cv.TM_CCOEFF_NORMED,
              mask: scaledMask,
            );
            final resGrad = cv.matchTemplate(
              refGradRegion,
              scaledGrad,
              cv.TM_CCOEFF_NORMED,
              mask: scaledMask,
            );

            // 混合權重：70% LAB 抗色偏色彩 + 30% Sobel 邊緣結構
            final combinedScore = cv.addWeighted(resLab, 0.70, resGrad, 0.30, 0.0);
            final (_, maxVal, _, maxLoc) = cv.minMaxLoc(combinedScore);

            if (maxVal.isFinite && maxVal > 0.25 && maxVal <= 1.05) {
              final double hitCenterX =
                  searchRoi.x + maxLoc.x + targetPatchW * 0.5;
              final double hitCenterY =
                  searchRoi.y + maxLoc.y + targetPatchH * 0.5;

              final double normX = (hitCenterX / refW).clamp(0.0, 1.0);
              final double normY = (hitCenterY / refH).clamp(0.0, 1.0);
              final double normW = (targetPatchW / refW).clamp(0.02, 0.25);
              final double normH = (targetPatchH / refH).clamp(0.02, 0.25);

              // 原圖正上方 (-90°) 在相機畫面中的方向角
              final double upArrowDeg =
                  _normalizeAngleDeg(-90.0 - totalPieceClockwiseRotDeg);

              final String engineTag =
                  pieceInfo.edgeType == PieceEdgeType.border ||
                          pieceInfo.edgeType == PieceEdgeType.corner
                      ? '多尺度模板 + ${pieceInfo.edgeType.displayName}幾何鎖定'
                      : '多尺度色彩/結構四向模板';

              candidates.add(
                CandidateLocation(
                  rank: 1,
                  overviewCenterNormalized: Offset(normX, normY),
                  overviewSizeNormalized: Size(normW, normH),
                  upArrowAngleInCameraDeg: upArrowDeg,
                  requiredClockwiseRotationDeg: totalPieceClockwiseRotDeg,
                  confidence: maxVal.clamp(0.25, 0.96),
                  engineUsed: engineTag,
                  matchedTileId: null,
                  matchedTileLabel: overviewTarget.label,
                ),
              );
            }

            refLabRegion.dispose();
            refGradRegion.dispose();
            resLab.dispose();
            resGrad.dispose();
            combinedScore.dispose();
          }

          scaledLab.dispose();
          scaledGrad.dispose();
          scaledMask.dispose();
        }

        rotLab.dispose();
        rotGrad.dispose();
        rotMask.dispose();
      }
    } finally {
      baseAlignedLab.dispose();
      baseAlignedGrad.dispose();
      baseAlignedMask.dispose();
    }

    return candidates;
  }

  /// 若拼圖塊具有「直邊（邊框塊）」或「雙直邊（角落塊）」，
  /// 根據直邊旋轉後的朝向，僅回傳對應的全貌圖外框搜尋區域！
  List<cv.Rect> _computeAllowedSearchRois({
    required PieceEdgeType edgeType,
    required List<double> flatNormalsInCameraDeg,
    required double appliedClockwiseRotDeg,
    required int refW,
    required int refH,
  }) {
    final fullRect = cv.Rect(0, 0, refW, refH);
    if (edgeType == PieceEdgeType.interior ||
        edgeType == PieceEdgeType.coreFallback ||
        flatNormalsInCameraDeg.isEmpty) {
      return [fullRect];
    }

    final int borderW = math.max(24, (refW * 0.14).round());
    final int borderH = math.max(24, (refH * 0.14).round());

    // 計算直邊外法線在套用旋轉後的角度：
    // Top: -90° (270°), Right: 0°, Bottom: 90°, Left: 180°
    final rotatedNormals = flatNormalsInCameraDeg
        .map((a) => _normalizeAngleDeg(a + appliedClockwiseRotDeg))
        .toList();

    bool hasTop = false;
    bool hasRight = false;
    bool hasBottom = false;
    bool hasLeft = false;

    for (final deg in rotatedNormals) {
      if (_angleDistanceDeg(deg, 270.0) < 35.0) hasTop = true;
      if (_angleDistanceDeg(deg, 0.0) < 35.0) hasRight = true;
      if (_angleDistanceDeg(deg, 90.0) < 35.0) hasBottom = true;
      if (_angleDistanceDeg(deg, 180.0) < 35.0) hasLeft = true;
    }

    if (edgeType == PieceEdgeType.corner) {
      if (hasTop && hasLeft) {
        return [cv.Rect(0, 0, borderW, borderH)];
      } else if (hasTop && hasRight) {
        return [cv.Rect(refW - borderW, 0, borderW, borderH)];
      } else if (hasBottom && hasRight) {
        return [cv.Rect(refW - borderW, refH - borderH, borderW, borderH)];
      } else if (hasBottom && hasLeft) {
        return [cv.Rect(0, refH - borderH, borderW, borderH)];
      }
    }

    if (edgeType == PieceEdgeType.border) {
      if (hasTop) {
        return [cv.Rect(0, 0, refW, borderH)];
      } else if (hasBottom) {
        return [cv.Rect(0, refH - borderH, refW, borderH)];
      } else if (hasLeft) {
        return [cv.Rect(0, 0, borderW, refH)];
      } else if (hasRight) {
        return [cv.Rect(refW - borderW, 0, borderW, refH)];
      }
    }

    return [fullRect];
  }

  /// 非極大值抑制 (NMS) 選出前 3 名不重疊的最佳候選位置
  List<CandidateLocation> _selectTop3DistinctCandidates(
      List<CandidateLocation> raw) {
    if (raw.isEmpty) return const [];
    final sorted = List<CandidateLocation>.from(raw)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    final selected = <CandidateLocation>[];
    const double minSeparationNorm = 0.065; // 全貌圖上至少相距 6.5% 才視為不同候選點

    for (final cand in sorted) {
      bool tooClose = false;
      for (final existing in selected) {
        final dist = (cand.overviewCenterNormalized -
                existing.overviewCenterNormalized)
            .distance;
        if (dist < minSeparationNorm) {
          tooClose = true;
          break;
        }
      }
      if (!tooClose) {
        selected.add(
          CandidateLocation(
            rank: selected.length + 1,
            overviewCenterNormalized: cand.overviewCenterNormalized,
            overviewSizeNormalized: cand.overviewSizeNormalized,
            upArrowAngleInCameraDeg: cand.upArrowAngleInCameraDeg,
            requiredClockwiseRotationDeg: cand.requiredClockwiseRotationDeg,
            confidence: cand.confidence,
            engineUsed: cand.engineUsed,
            matchedTileId: cand.matchedTileId,
            matchedTileLabel: cand.matchedTileLabel,
          ),
        );
        if (selected.length >= 3) break;
      }
    }
    return selected;
  }

  static Offset? _projectPoint(List<double> h, double x, double y) {
    final denom = h[6] * x + h[7] * y + h[8];
    if (denom.abs() < 1e-9) return null;
    return Offset(
      (h[0] * x + h[1] * y + h[2]) / denom,
      (h[3] * x + h[4] * y + h[5]) / denom,
    );
  }

  static cv.Mat _rotateMatKeepSize(
    cv.Mat src,
    double angleDeg, {
    required double borderVal,
  }) {
    if (angleDeg.abs() < 1.0) return src.clone();
    final center = cv.Point2f(src.cols * 0.5, src.rows * 0.5);
    final rotMat = cv.getRotationMatrix2D(center, angleDeg, 1.0);
    final dst = cv.warpAffine(
      src,
      rotMat,
      (src.cols, src.rows),
      borderValue: cv.Scalar.all(borderVal),
    );
    rotMat.dispose();
    return dst;
  }

  static cv.Mat _rotateOrthogonal(cv.Mat src, int orthoDeg) {
    switch (orthoDeg % 360) {
      case 90:
        return cv.rotate(src, cv.ROTATE_90_CLOCKWISE);
      case 180:
        return cv.rotate(src, cv.ROTATE_180);
      case 270:
        return cv.rotate(src, cv.ROTATE_90_COUNTERCLOCKWISE);
      default:
        return src.clone();
    }
  }

  static double _normalizeAngleDeg(double deg) {
    double a = deg % 360.0;
    if (a > 180.0) a -= 360.0;
    if (a <= -180.0) a += 360.0;
    return a;
  }

  static double _angleDistanceDeg(double a, double b) {
    double diff = (a - b).abs() % 360.0;
    return diff > 180.0 ? 360.0 - diff : diff;
  }

  void dispose() {
    _overviewTarget?.dispose();
    _overviewTarget = null;
    for (final t in _detailTargets) {
      t.dispose();
    }
    _detailTargets.clear();
    _isInitialized = false;
  }
}
