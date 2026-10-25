import 'dart:math' as math;
import 'dart:ui';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../../models/match_result.dart';

/// 單塊目標拼圖分割結果（包含裁切後的影像與內縮去背遮罩）
class SegmentedTargetPatch {
  final DetectedPiece pieceInfo;

  /// 裁切出的拼圖塊局部 BGR 影像 (由呼叫端負責 dispose)
  final cv.Mat croppedBgr;

  /// 向內侵蝕後的拼圖塊二值遮罩 (uint8, 255=拼圖內部有效圖案, 0=桌面背景與邊緣陰影)
  final cv.Mat erodedMask;

  const SegmentedTargetPatch({
    required this.pieceInfo,
    required this.croppedBgr,
    required this.erodedMask,
  });

  void dispose() {
    croppedBgr.dispose();
    erodedMask.dispose();
  }
}

/// 自適應桌面去背、內縮遮罩與直邊（邊框塊）幾何檢測器
class PieceSegmenter {
  /// 分析單幀相機 BGR 影像：
  /// 1. 自動取樣畫面周邊作為桌面背景色，分割出畫面中所有拼圖塊輪廓。
  /// 2. 鎖定最靠近 [targetPointNormalized]（預設為中央準星 0.5, 0.5）的拼圖塊。
  /// 3. 建立微幅內縮遮罩 (Eroded Mask) 並分析是否含「直邊（邊框塊/角落塊）」。
  /// 4. 若桌面紋理過於複雜無法分割輪廓，自動退回「準星圓形核心取樣」保底模式。
  static ({
    List<DetectedPiece> allPieces,
    SegmentedTargetPatch targetPatch,
  }) segmentFrame({
    required cv.Mat frameBgr,
    Offset targetPointNormalized = const Offset(0.5, 0.5),
  }) {
    final int frameW = frameBgr.cols;
    final int frameH = frameBgr.rows;
    final double frameArea = (frameW * frameH).toDouble();

    final lab = cv.cvtColor(frameBgr, cv.COLOR_BGR2Lab);
    final gray = cv.cvtColor(frameBgr, cv.COLOR_BGR2GRAY);

    // 1. 取樣畫面四周邊框 (8% 寬度) 估計桌面背景 LAB 色彩分佈
    final bgMask = cv.Mat.zeros(frameH, frameW, cv.MatType.CV_8UC1);
    final int marginX = math.max(8, (frameW * 0.08).round());
    final int marginY = math.max(8, (frameH * 0.08).round());

    cv.rectangle(
      bgMask,
      cv.Rect(0, 0, frameW, frameH),
      cv.Scalar.all(255),
      thickness: -1,
    );
    cv.rectangle(
      bgMask,
      cv.Rect(marginX, marginY, frameW - 2 * marginX, frameH - 2 * marginY),
      cv.Scalar.all(0),
      thickness: -1,
    );

    final (meanBg, stdBg) = cv.meanStdDev(lab, mask: bgMask);
    bgMask.dispose();

    // 計算與桌面背景的色差遮罩
    final double tolL = math.max(22.0, stdBg.val1 * 2.4);
    final double tolA = math.max(12.0, stdBg.val2 * 2.6);
    final double tolB = math.max(12.0, stdBg.val3 * 2.6);

    final lowerBg = cv.Mat.fromScalar(
      frameH,
      frameW,
      cv.MatType.CV_8UC3,
      cv.Scalar(
        (meanBg.val1 - tolL).clamp(0, 255),
        (meanBg.val2 - tolA).clamp(0, 255),
        (meanBg.val3 - tolB).clamp(0, 255),
        0,
      ),
    );
    final upperBg = cv.Mat.fromScalar(
      frameH,
      frameW,
      cv.MatType.CV_8UC3,
      cv.Scalar(
        (meanBg.val1 + tolL).clamp(0, 255),
        (meanBg.val2 + tolA).clamp(0, 255),
        (meanBg.val3 + tolB).clamp(0, 255),
        255,
      ),
    );

    final inBgRange = cv.inRange(lab, lowerBg, upperBg);
    final fgColorMask = cv.bitwiseNOT(inBgRange);

    // 結合 Canny 邊緣強化低色差拼圖塊邊界
    final blurredGray = cv.gaussianBlur(gray, (5, 5), 1.2);
    final edges = cv.canny(blurredGray, 40, 120);
    final combinedFg = cv.bitwiseOR(fgColorMask, edges);

    final closeKernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (9, 9));
    final openKernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (5, 5));
    final closed = cv.morphologyEx(combinedFg, cv.MORPH_CLOSE, closeKernel);
    final cleanedMask = cv.morphologyEx(closed, cv.MORPH_OPEN, openKernel);

    // 釋放前處理暫存矩陣
    lab.dispose();
    gray.dispose();
    lowerBg.dispose();
    upperBg.dispose();
    inBgRange.dispose();
    fgColorMask.dispose();
    blurredGray.dispose();
    edges.dispose();
    combinedFg.dispose();
    closeKernel.dispose();
    openKernel.dispose();
    closed.dispose();

    // 2. 尋找候選拼圖塊輪廓
    final (contours, _) =
        cv.findContours(cleanedMask, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
    cleanedMask.dispose();

    final detectedPieces = <DetectedPiece>[];
    final validContourIndices = <int>[];

    final double minPieceArea = frameArea * 0.008; // 至少佔畫面 0.8%
    final double maxPieceArea = frameArea * 0.55; // 至多佔畫面 55%

    for (int i = 0; i < contours.length; i++) {
      final contour = contours[i];
      final area = cv.contourArea(contour);
      if (area < minPieceArea || area > maxPieceArea) continue;

      final rect = cv.boundingRect(contour);
      final double aspect =
          rect.width / math.max(1.0, rect.height.toDouble());
      if (aspect < 0.35 || aspect > 2.8) continue;

      final rotRect = cv.minAreaRect(contour);
      final centerNorm = Offset(
        (rotRect.center.x / frameW).clamp(0.0, 1.0),
        (rotRect.center.y / frameH).clamp(0.0, 1.0),
      );
      final bboxNorm = Rect.fromLTWH(
        (rect.x / frameW).clamp(0.0, 1.0),
        (rect.y / frameH).clamp(0.0, 1.0),
        (rect.width / frameW).clamp(0.01, 1.0),
        (rect.height / frameH).clamp(0.01, 1.0),
      );

      // 簡化多邊形供 UI 繪製 AR 輪廓
      final peri = cv.arcLength(contour, true);
      final approx = cv.approxPolyDP(contour, 0.012 * peri, true);
      final polyNorm = <Offset>[];
      for (int j = 0; j < approx.length; j++) {
        final pt = approx[j];
        polyNorm.add(Offset(pt.x / frameW, pt.y / frameH));
      }
      approx.dispose();

      // 分析四邊是否含有直邊（邊框塊或角落塊）
      final edgeAnalysis = _analyzeContourEdges(contour, rotRect);

      final pieceId = detectedPieces.length + 1;
      detectedPieces.add(
        DetectedPiece(
          id: pieceId,
          boundingBoxNormalized: bboxNorm,
          centerNormalized: centerNorm,
          contourPointsNormalized: polyNorm,
          principalAngleDeg: rotRect.angle,
          edgeType: edgeAnalysis.edgeType,
          flatEdgeNormalAnglesDeg: edgeAnalysis.flatNormalsDeg,
          isLockedTarget: false,
        ),
      );
      validContourIndices.add(i);
    }

    // 3. 若成功分割出拼圖塊，選出距離 targetPointNormalized 最近的拼圖塊作為鎖定目標
    if (detectedPieces.isNotEmpty) {
      int bestIdx = 0;
      double minDist = double.infinity;
      for (int i = 0; i < detectedPieces.length; i++) {
        final d =
            (detectedPieces[i].centerNormalized - targetPointNormalized).distance;
        if (d < minDist) {
          minDist = d;
          bestIdx = i;
        }
      }

      // 標記鎖定目標
      for (int i = 0; i < detectedPieces.length; i++) {
        if (i == bestIdx) {
          detectedPieces[i] = detectedPieces[i].copyWith(isLockedTarget: true);
        }
      }

      final activePiece = detectedPieces[bestIdx];
      final targetContour = contours[validContourIndices[bestIdx]];
      final rect = cv.boundingRect(targetContour);

      // 建立該拼圖塊的局部遮罩並向內侵蝕 (Erode 6% 寬度)，排除邊緣陰影與桌面背景
      final roiRect = cv.Rect(
        rect.x.clamp(0, frameW - 2),
        rect.y.clamp(0, frameH - 2),
        rect.width.clamp(2, frameW - rect.x),
        rect.height.clamp(2, frameH - rect.y),
      );

      final fullPieceMask = cv.Mat.zeros(frameH, frameW, cv.MatType.CV_8UC1);
      final singleContourVec = cv.VecVecPoint.fromList([targetContour.toList()]);
      cv.drawContours(
        fullPieceMask,
        singleContourVec,
        0,
        cv.Scalar.all(255),
        thickness: -1,
      );
      singleContourVec.dispose();

      final croppedBgr = frameBgr.region(roiRect).clone();
      final croppedMask = fullPieceMask.region(roiRect).clone();
      fullPieceMask.dispose();

      final int erodeRadius =
          math.max(3, (math.min(roiRect.width, roiRect.height) * 0.065).round());
      final erodeKernel = cv.getStructuringElement(
        cv.MORPH_ELLIPSE,
        (erodeRadius * 2 + 1, erodeRadius * 2 + 1),
      );
      final erodedMask = cv.erode(croppedMask, erodeKernel);
      erodeKernel.dispose();
      croppedMask.dispose();
      contours.dispose();

      return (
        allPieces: detectedPieces,
        targetPatch: SegmentedTargetPatch(
          pieceInfo: activePiece,
          croppedBgr: croppedBgr,
          erodedMask: erodedMask,
        ),
      );
    }

    contours.dispose();

    // 4. 保底機制：若桌面背景複雜無法分割出輪廓，自動擷取準星中央圓形核心圖案
    final double radiusPx = math.min(frameW, frameH) * 0.14;
    final int cx = (targetPointNormalized.dx * frameW).round().clamp(
          radiusPx.round() + 2,
          frameW - radiusPx.round() - 2,
        );
    final int cy = (targetPointNormalized.dy * frameH).round().clamp(
          radiusPx.round() + 2,
          frameH - radiusPx.round() - 2,
        );
    final int r = radiusPx.round();

    final roiRect = cv.Rect(cx - r, cy - r, r * 2, r * 2);
    final croppedBgr = frameBgr.region(roiRect).clone();
    final circleMask = cv.Mat.zeros(r * 2, r * 2, cv.MatType.CV_8UC1);
    cv.circle(
      circleMask,
      cv.Point(r, r),
      (r * 0.88).round(),
      cv.Scalar.all(255),
      thickness: -1,
    );

    // 產生圓形多邊形頂點供 AR 畫面呈現
    final circlePoly = <Offset>[];
    for (int k = 0; k < 24; k++) {
      final theta = k * 2 * math.pi / 24;
      circlePoly.add(
        Offset(
          (cx + r * math.cos(theta)) / frameW,
          (cy + r * math.sin(theta)) / frameH,
        ),
      );
    }

    final fallbackPiece = DetectedPiece(
      id: 1,
      boundingBoxNormalized: Rect.fromLTRB(
        (cx - r) / frameW,
        (cy - r) / frameH,
        (cx + r) / frameW,
        (cy + r) / frameH,
      ),
      centerNormalized: Offset(cx / frameW, cy / frameH),
      contourPointsNormalized: circlePoly,
      principalAngleDeg: 0.0,
      edgeType: PieceEdgeType.coreFallback,
      flatEdgeNormalAnglesDeg: const [],
      isLockedTarget: true,
    );

    return (
      allPieces: [fallbackPiece],
      targetPatch: SegmentedTargetPatch(
        pieceInfo: fallbackPiece,
        croppedBgr: croppedBgr,
        erodedMask: circleMask,
      ),
    );
  }

  /// 分析拼圖輪廓四個邊是否平直（無凹凸齒），判斷是否為「直邊外框塊」或「角落塊」
  static ({PieceEdgeType edgeType, List<double> flatNormalsDeg})
      _analyzeContourEdges(cv.VecPoint contour, cv.RotatedRect rotRect) {
    final double w = rotRect.size.width;
    final double h = rotRect.size.height;
    if (w < 20 || h < 20 || contour.length < 16) {
      return (edgeType: PieceEdgeType.interior, flatNormalsDeg: const []);
    }

    final double angleRad = rotRect.angle * math.pi / 180.0;
    final double cosA = math.cos(-angleRad);
    final double sinA = math.sin(-angleRad);
    final double cx = rotRect.center.x;
    final double cy = rotRect.center.y;

    // 分別收集四個方向的局部座標偏移量 (Top: -Y, Right: +X, Bottom: +Y, Left: -X)
    final sideDeviations = List.generate(4, (_) => <double>[]);

    for (int i = 0; i < contour.length; i++) {
      final pt = contour[i];
      final dx = pt.x - cx;
      final dy = pt.y - cy;
      final lx = dx * cosA - dy * sinA;
      final ly = dx * sinA + dy * cosA;

      final nx = lx / (w * 0.5);
      final ny = ly / (h * 0.5);

      // 忽略四個角落區域 (-0.65 ~ +0.65 之間才算邊中段)
      if (nx.abs() < 0.65 && ny < -0.25) {
        sideDeviations[0].add(ny.abs()); // Top
      } else if (ny.abs() < 0.65 && nx > 0.25) {
        sideDeviations[1].add(nx.abs()); // Right
      } else if (nx.abs() < 0.65 && ny > 0.25) {
        sideDeviations[2].add(ny.abs()); // Bottom
      } else if (ny.abs() < 0.65 && nx < -0.25) {
        sideDeviations[3].add(nx.abs()); // Left
      }
    }

    // 對應四邊在局部座標系的外法線角度：Top(-90°), Right(0°), Bottom(90°), Left(180°)
    const localNormals = [-90.0, 0.0, 90.0, 180.0];
    final flatSideIndices = <int>[];
    final flatNormals = <double>[];

    for (int s = 0; s < 4; s++) {
      final vals = sideDeviations[s];
      if (vals.length < 4) continue;
      double minV = vals.first;
      double maxV = vals.first;
      for (final v in vals) {
        if (v < minV) minV = v;
        if (v > maxV) maxV = v;
      }
      // 若該邊中段的最大與最小法向起伏差小於 0.11 (無凸頭也無凹槽)，即判定為直邊
      if ((maxV - minV) < 0.11) {
        flatSideIndices.add(s);
        final worldNormal = (rotRect.angle + localNormals[s]) % 360.0;
        flatNormals.add(worldNormal < 0 ? worldNormal + 360.0 : worldNormal);
      }
    }

    if (flatSideIndices.length == 2 &&
        ((flatSideIndices[1] - flatSideIndices[0]).abs() == 1 ||
            (flatSideIndices[1] - flatSideIndices[0]).abs() == 3)) {
      return (edgeType: PieceEdgeType.corner, flatNormalsDeg: flatNormals);
    } else if (flatSideIndices.length == 1) {
      return (edgeType: PieceEdgeType.border, flatNormalsDeg: flatNormals);
    }
    return (edgeType: PieceEdgeType.interior, flatNormalsDeg: const []);
  }
}
