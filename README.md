# Capit

一个菜单栏常驻的 macOS 截图标注工具（AppKit 纯程序化，无第三方依赖）。截图后自动加连续圆角 + 原生风格阴影，弹出右下角预览缩略图，点击即可进入标注编辑器；标注结果保存到桌面。也可直接从菜单导入本地图片进行标注。

当前版本：**v0.5**

## 功能特性

- **三种截图模式**（菜单栏或全局快捷键）
  - 全屏截图：`⇧⌘3`（也支持 `⇧⌘9`）
  - 区域 / 窗口截图：`⇧⌘4`（也支持 `⇧⌘0`）
- **交互式框选**：拖拽框选区域；**空格**在「区域 ↔ 窗口」间切换；**ESC** 取消。区域拖拽中按住空格可整体移动选区；窗口模式按真实 Z 序选窗（CGWindowList），悬停高亮，点按或回车截取当前窗口。
- **后处理**：连续圆角 + 原生风格投影，截图时播放系统快门声。
- **右下角预览**：新截图**替换**旧预览（旧图立即落盘），只保留一张；点击进编辑器，超时自动落到桌面。
- **标注编辑器**（菜单「编辑器」或 `⌘E`）：
  - 工具：矩形 / 椭圆 / 箭头（90° 每臂，臂长=杆长 2/5）/ 直线 / 荧光笔（固定 50% 透明度）/ 文字 / 序号 / 马赛克（纯色填充，默认黑）。
  - 支持颜色、线宽、实/虚线、字号；选中即**就地修改**（颜色/宽度/字号/实虚线）；`Cmd+S` 保存，`Cmd+Z`/`⇧Cmd+Z` 撤销重做，`Delete` 删除，**方向键移动选中图形**（`⇧` 加速）；数字自动排序。
  - 打开时默认不选中任何工具；线型/线宽在切换工具或形状时回到默认（实线 / 3，荧光笔 16）。
- **导入本地图片标注**（菜单「编辑器」）：支持 **png / jpg**，自动套用圆角 + 阴影后进入编辑器，保存为 **PNG**。
  - **已带圆角/阴影的图片不再重复处理**：Capit 自己导出的 PNG（内嵌标记）或 macOS 原生窗口截图（alpha/几何启发式判定）会原样打开，跳过二次圆角与阴影。
- **关于**：菜单「关于」显示当前版本。
- **自动退出**：连续 10 分钟无截图/标注操作自动退出（可用环境变量 `CAPIT_IDLE_SECONDS` 覆盖秒数，便于测试）。

## 运行环境

- macOS 13.0+
- Apple Silicon（arm64）
- 需要**屏幕录制**权限（截图功能）

## 构建与打包

```bash
# 仅编译可执行文件
swift build -c release

# 打 .app（ad-hoc 签名，写入 build/Capit.app）
./make_app.sh release

# 启动
open build/Capit.app
```

产物 `build/Capit.app` 完全自包含（单可执行文件 + 图标 + Info.plist），无外部框架，可直接拷贝到别的 Mac。

## 仓库 / 许可

- 源码仓库：`git@github.com:dct74/capit.git`（SSH）
- 以源码构建时，`.build/` 与 `build/` 为本地产物，已在 `.gitignore` 中排除。
- 许可：MIT（见 `LICENSE`）。

## 授权提示

系统设置 → 隐私与安全性 → 屏幕录制：添加并勾选 Capit，授权后**完全退出并重开**生效。ad-hoc 签名应用每次重编译/重签会导致签名变化、授权被重置，需要重新授权。

## 目录结构

```
Package.swift
make_app.sh
LICENSE
resources/AppIcon.icns   AppIcon.png
Sources/Capit/
  main.swift  AppDelegate.swift  GlobalHotKey.swift
  CaptureController.swift  CaptureKit.swift  InteractiveCapture.swift
  ImageProcessor.swift  PreviewWindowController.swift  CapturePipeline.swift
  AnnotationEditor.swift  Squircle.swift
```
