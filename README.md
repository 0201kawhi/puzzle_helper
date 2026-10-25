# 拼圖助手 AR (Puzzle Helper)

一款採用 **Flutter + 本地端 C++ OpenCV (`opencv_dart`)** 開發的跨平台即時 AR 拼圖輔助定位 App。所有影像分割、抗色偏前處理與雙引擎特徵/多尺度模板匹配皆 100% 在手機本地離線執行，無需伺服器或網路連線。

---

## 核心功能亮點

1. **「1張全貌底圖 + 多張高解析局部圖」混合映射 (`ReferenceMapper`)**
   - 先拍攝 1 張拼圖外盒或完成圖，透過互動式 **四點透視校正 (`PerspectiveCorrector`)** 自動將斜拍梯形拉正為標準矩形導航底圖。
   - 支援近距離補拍多張「高解析度局部特寫圖」（如分成 4 宮格或 6 宮格拍攝），解決單張照片解析度不足或外盒局部反光問題。
   - 系統自動使用 AKAZE 特徵點與 RANSAC 計算每張局部圖對應回全貌底圖的 $3 \times 3$ 單應性矩陣（Homography），比對時直接對高畫質局部圖進行比對再將座標投射回全貌圖，避免傳統全景拼接（Stitching）接縫變形。

2. **即時鏡頭 AR 串流 + 準星鎖定/多片點擊切換 (`ArScannerScreen` & `ArCameraOverlay`)**
   - 預設鎖定鏡頭中央準星的拼圖塊，同時自動框出畫面中其他散落拼圖塊，手指點擊任一塊即可切換目標。
   - 在拼圖塊上直接繪製 **AR 正向箭頭 (`↑ 正上方`)** 與順/逆時針旋轉指引（如 `順時針轉 90° ↻`）。
   - 提供 **「定格畫面 (Freeze Frame)」** 按鈕，隨時暫停即時串流以仔細對照原圖與局部放大卡。
   - 支援 **上下分割畫面 (Split View)** 與 **全螢幕 AR 相機 + 角落浮動子母畫面 (PiP)** 一鍵切換。

3. **本地端 OpenCV 混合雙引擎 + 幾何方向約束 (`PieceSegmenter` & `PuzzleMatcher`)**
   - **自適應桌面去背 + 內縮遮罩 (`Eroded Mask`)**：取樣畫面外圍估計桌面背景色，分割出拼圖輪廓並向內微幅侵蝕以排除邊緣陰影與背景干擾；若遇複雜木紋桌面則自動切換為「準星圓形核心取樣」保底。
   - **智慧抗色偏**：自動執行 `CIE LAB` 色彩空間轉換、`CLAHE` 局部對比度均衡與色溫偏移校正，並結合 `Sobel` 邊緣梯度結構。
   - **階段一（AKAZE 特徵引擎）**：針對有豐富線條細節的拼圖塊，直接跨尺度、跨 360° 旋轉角秒速定位。
   - **階段二（免輸入片數多尺度金字塔 + 四向正交角模板引擎 + 直邊外框約束）**：針對漸層天空、水面、草地等低紋理色塊，利用 `minAreaRect` 主軸對齊後僅需測試 `0°/90°/180°/270°` 四個方向，並在 6 個尺度階層下搜尋；若偵測到拼圖塊含 **「直邊（邊框塊）」** 或 **「雙直邊（角落塊）」**，自動僅搜尋原圖四邊外框並鎖定朝向！

---

## 如何打包 Android APK 進行實機測試

### 方式 A：使用 GitHub Actions 雲端自動打包 APK（免在本機安裝開發環境）
本專案已內建 [`.github/workflows/build_apk.yml`](.github/workflows/build_apk.yml) 自動化建置腳本：
1. 將 `D:\puzzle_helper` 推送至你的 GitHub 儲存庫（Repository）。
2. 進入 GitHub 儲存庫頁面的 **Actions** 頁籤，點選 **Build Android APK** 工作流。
3. 建置完成後，即可在頁面下方的 **Artifacts** 區塊直接下載 `puzzle-helper-release-apk`（內含 `app-release.apk`）傳送到 Android 手機安裝！

### 方式 B：在 Windows 本機安裝 Flutter 編譯與實機除錯
1. 安裝 [Flutter SDK (3.24+)](https://docs.flutter.dev/get-started/install/windows/mobile) 與 Android Studio（勾選 Android SDK Command-line Tools 與 NDK）。
2. 在專案根目錄 `D:\puzzle_helper` 開啟終端機執行：
   ```powershell
   # 補齊平台預設原生殼層檔案（保留本專案已客製化的 AndroidManifest.xml 與 lib/ 程式碼）
   flutter create . --project-name puzzle_helper --org com.puzzlehelper.app --platforms android

   # 下載依賴套件 (含 camera 與 opencv_dart C++ 二進位庫)
   flutter pub get

   # 連接 Android 手機（開啟 USB 偵錯）直接執行或打包 Release APK
   flutter run --release
   # 或打包 APK：
   flutter build apk --release --target-platform android-arm64
   ```
