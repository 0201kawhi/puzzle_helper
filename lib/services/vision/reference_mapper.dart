import 'dart:math' as math;
import 'dart:ui';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../../models/puzzle_project.dart';

/// 「1張全貌底圖 + 多張高解析局部圖」混合映射與光影正規化服務
///
/// 1. 提供智慧抗色偏前處理 (LAB 空間 + CLAHE 局部對比度均衡 + 色度均值校正)。
/// 2. 自動計算每張「高解析度局部特寫圖 (DetailTile)」對應回「全貌底圖 (Overview)」的
///    3x3 單應性矩陣 (Homography)，免除傳統全景拼接縫隙變形問題。
class ReferenceMapper {
  /// 智慧抗色偏與局部對比增強：
  /// 將 BGR 影像轉換至 CIE LAB 色彩空間，對 L 亮度通道執行 CLAHE 消除反光與陰影，
  /// 並對 A/B 色度通道進行色溫偏移校正（降低室內暖黃光影響），同時回傳正規化後的 BGR 與灰階圖。
  static ({cv.Mat normalizedBgr, cv.Mat claheGray, cv.Mat labImage})
      normalizeIlluminationAndColor(cv.Mat bgrInput) {
    final lab = cv.cvtColor(bgrInput, cv.COLOR_BGR2Lab);
    final channels = cv.split(lab);
    final lChannel = channels[0];
    final aChannel = channels[1];
    final bChannel = channels[2];

    // 對亮度通道 L 執行 CLAHE (ClipLimit=2.5, TileGrid=8x8)
    final clahe = cv.createCLAHE(clipLimit: 2.5, tileGridSize: (8, 8));
    final lClahe = clahe.apply(lChannel);
    clahe.dispose();

    // 計算 A, B 色度通道平均偏移，補償檯燈黃光/冷白光色偏 (Gray-World Chromaticity Shift)
    final meanA = cv.mean(aChannel).val1;
    final meanB = cv.mean(bChannel).val1;
    final deltaA = (128.0 - meanA).clamp(-18.0, 18.0);
    final deltaB = (128.0 - meanB).clamp(-22.0, 22.0);

    final aCorrected = cv.convertScaleAbs(aChannel, alpha: 1.0, beta: deltaA);
    final bCorrected = cv.convertScaleAbs(bChannel, alpha: 1.0, beta: deltaB);

    final mergedVec = cv.VecMat.fromList([lClahe, aCorrected, bCorrected]);
    final normalizedLab = cv.merge(mergedVec);
    final normalizedBgr = cv.cvtColor(normalizedLab, cv.COLOR_Lab2BGR);

    // 釋放中間暫存矩陣
    lab.dispose();
    channels.dispose();
    lChannel.dispose();
    aChannel.dispose();
    bChannel.dispose();
    aCorrected.dispose();
    bCorrected.dispose();
    mergedVec.dispose();

    return (
      normalizedBgr: normalizedBgr,
      claheGray: lClahe,
      labImage: normalizedLab,
    );
  }

  /// 計算 Sobel 邊緣梯度幅值圖 (0~255 uint8)，用於色彩+結構混合比對
  static cv.Mat computeGradientMagnitude(cv.Mat gray) {
    final gradX = cv.sobel(gray, cv.MatType.CV_16S, 1, 0, ksize: 3);
    final gradY = cv.sobel(gray, cv.MatType.CV_16S, 0, 1, ksize: 3);
    final absX = cv.convertScaleAbs(gradX);
    final absY = cv.convertScaleAbs(gradY);
    final grad = cv.addWeighted(absX, 0.5, absY, 0.5, 0);

    gradX.dispose();
    gradY.dispose();
    absX.dispose();
    absY.dispose();
    return grad;
  }

  /// 將新拍攝的「高畫質局部特寫圖」自動與「全貌底圖」進行 AKAZE 特徵對齊，
  /// 計算 3x3 Homography 矩陣與在全貌圖上的覆蓋範圍。
  static DetailTile alignDetailTileToOverview({
    required String tileId,
    required String label,
    required String tileImagePath,
    required String overviewImagePath,
  }) {
    final overviewMat = cv.imread(overviewImagePath);
    final tileMat = cv.imread(tileImagePath);

    if (overviewMat.isEmpty || tileMat.isEmpty) {
      overviewMat.dispose();
      tileMat.dispose();
      throw Exception('無法讀取全貌圖或局部特寫圖');
    }

    final int ovW = overviewMat.cols;
    final int ovH = overviewMat.rows;
    final int tileW = tileMat.cols;
    final int tileH = tileMat.rows;

    final ovNorm = normalizeIlluminationAndColor(overviewMat);
    final tileNorm = normalizeIlluminationAndColor(tileMat);

    final akaze = cv.AKAZE.empty();
    final matcher = cv.BFMatcher.create(type: cv.NORM_HAMMING);

    try {
      final (kpOv, descOv) =
          akaze.detectAndCompute(ovNorm.claheGray, cv.Mat.empty());
      final (kpTile, descTile) =
          akaze.detectAndCompute(tileNorm.claheGray, cv.Mat.empty());

      if (descOv.isEmpty ||
          descTile.isEmpty ||
          kpOv.length < 8 ||
          kpTile.length < 8) {
        kpOv.dispose();
        descOv.dispose();
        kpTile.dispose();
        descTile.dispose();
        return DetailTile(
          id: tileId,
          label: label,
          imagePath: tileImagePath,
          width: tileW,
          height: tileH,
          homographyToOverview: null,
          coverageRectNormalized: null,
          inlierCount: 0,
        );
      }

      final knnMatches = matcher.knnMatch(descTile, descOv, 2);
      final srcPtsList = <cv.Point2f>[];
      final dstPtsList = <cv.Point2f>[];

      for (int i = 0; i < knnMatches.length; i++) {
        final pair = knnMatches[i];
        if (pair.length >= 2) {
          final m = pair[0];
          final n = pair[1];
          if (m.distance < 0.78 * n.distance) {
            final kpT = kpTile[m.queryIdx];
            final kpO = kpOv[m.trainIdx];
            srcPtsList.add(cv.Point2f(kpT.x, kpT.y));
            dstPtsList.add(cv.Point2f(kpO.x, kpO.y));
          }
        }
      }

      List<double>? hList;
      Rect? coverageNormalized;
      int inliers = 0;

      if (srcPtsList.length >= 8) {
        final srcVec = cv.VecPoint2f.fromList(srcPtsList);
        final dstVec = cv.VecPoint2f.fromList(dstPtsList);
        final srcMat = cv.Mat.fromVec(srcVec);
        final dstMat = cv.Mat.fromVec(dstVec);
        final mask = cv.Mat.empty();

        final hMat = cv.findHomography(
          srcMat,
          dstMat,
          method: cv.RANSAC,
          ransacReprojThreshold: 5.0,
          mask: mask,
        );

        if (!hMat.isEmpty && hMat.rows == 3 && hMat.cols == 3) {
          // 統計 RANSAC 內點數
          inliers = cv.countNonZero(mask);
          if (inliers >= 6) {
            hList = <double>[
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

            final tempTile = DetailTile(
              id: tileId,
              label: label,
              imagePath: tileImagePath,
              width: tileW,
              height: tileH,
              homographyToOverview: hList,
            );

            // 投射局部圖四個角點到全貌圖，計算正規化覆蓋範圍
            final corners = [
              tempTile.projectToOverviewPixel(0, 0),
              tempTile.projectToOverviewPixel(tileW.toDouble(), 0),
              tempTile.projectToOverviewPixel(
                  tileW.toDouble(), tileH.toDouble()),
              tempTile.projectToOverviewPixel(0, tileH.toDouble()),
            ].whereType<Offset>().toList();

            if (corners.length == 4) {
              double minX = corners.first.dx;
              double maxX = corners.first.dx;
              double minY = corners.first.dy;
              double maxY = corners.first.dy;
              for (final c in corners) {
                minX = math.min(minX, c.dx);
                maxX = math.max(maxX, c.dx);
                minY = math.min(minY, c.dy);
                maxY = math.max(maxY, c.dy);
              }
              coverageNormalized = Rect.fromLTRB(
                (minX / ovW).clamp(0.0, 1.0),
                (minY / ovH).clamp(0.0, 1.0),
                (maxX / ovW).clamp(0.0, 1.0),
                (maxY / ovH).clamp(0.0, 1.0),
              );
            }
          }
        }

        srcVec.dispose();
        dstVec.dispose();
        srcMat.dispose();
        dstMat.dispose();
        mask.dispose();
        hMat.dispose();
      }

      knnMatches.dispose();
      kpOv.dispose();
      descOv.dispose();
      kpTile.dispose();
      descTile.dispose();

      return DetailTile(
        id: tileId,
        label: label,
        imagePath: tileImagePath,
        width: tileW,
        height: tileH,
        homographyToOverview: hList,
        coverageRectNormalized: coverageNormalized,
        inlierCount: inliers,
      );
    } finally {
      akaze.dispose();
      matcher.dispose();
      ovNorm.normalizedBgr.dispose();
      ovNorm.claheGray.dispose();
      ovNorm.labImage.dispose();
      tileNorm.normalizedBgr.dispose();
      tileNorm.claheGray.dispose();
      tileNorm.labImage.dispose();
      overviewMat.dispose();
      tileMat.dispose();
    }
  }
}
