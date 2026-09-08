# HelloX 全项目 Codex 图标来源清单

更新时间：2026-09-07。只读提取已安装 Codex 的静态 UI 文件，未访问账号、会话或应用数据库，也未执行其 JavaScript。

## 统一规范

- 原生 Codex 图标保留原始 SVG 路径与 16 或 20 单位光学画布，渲染时统一使用功能所在控件的尺寸。所有图标使用 `currentColor` 并由应用作为单色模板着色。
- Codex 原生 Light 20 图标约 1.33 单位线宽；Light 16 图标约 1.05 单位线宽。两者在 16 pt 显示时的视觉粗细一致。
- 个别专用功能在 Codex 原生集合中没有同义图标，使用 Codex 实际随应用分发的 Lucide 对应矢量；保留路径，24 单位画布的线宽改为 1.6，对齐 16 pt 下约 1.067 pt 的光学粗细。这些是适配图标，不宣称为未改动的 Codex 自有原图。
- 不修改 HelloX 品牌 LOGO、菜单栏品牌图标、VendorIcons 或系统返回的第三方应用图标。

## 逐项映射

| 项目资源（.svg） | Codex 资源 | 类型 | 适配 | 来源 |
|---|---|---|---|---|
| `accessibility` | `Accessibility` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/accessibility-BaVhniro-aaf5e386db10.js` |
| `app-window` | `appshot-window-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-primary-6cd7b8b3f5e3.js` |
| `brush` | `pencil-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `check` | `checkmark-md-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `chevron-down` | `chevron-down-md-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `chevron-right` | `chevron-right-md-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `chevron-up` | `chevron-down-md-light-20` | Codex native | translate(20 20) rotate(180) | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `circle` | `circle-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-primary-6cd7b8b3f5e3.js` |
| `circle-check` | `checkmark-circle-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `code` | `code-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `command` | `Lt / keyboard-shortcuts` | Codex settings component | Original SVG geometry and 20 x 20 canvas | `/webview/assets/use-visible-settings-sections-8b7372fb2441.js` |
| `copy` | `square-on-square-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `crop` | `Crop` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/crop-D9YhCwTh-5d1e1412b3da.js` |
| `crosshair` | `Crosshair` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/crosshair-De-2moBE-766196a69e9d.js` |
| `download` | `arrow-down-line-horizontal-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `edit` | `square-and-pencil-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `eye` | `eye-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `file-text` | `text-document-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `highlight` | `text-select-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/subagent-activity-chip-group-985efc2d5846.js` |
| `info` | `info-circle-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `key` | `KeyRound` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/key-round-LoA5dLqg-2ef3c961182c.js` |
| `languages` | `translate-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-primary-6cd7b8b3f5e3.js` |
| `lightbulb` | `lightbulb-rays-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `list-ordered` | `ListOrdered` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/list-ordered-db1dmAOz-b366779d0a3a.js` |
| `local-translation` | `translate-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-primary-6cd7b8b3f5e3.js` |
| `markdown` | `FileCode` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/file-code-K2bqsZvW-2851149f82fd.js` |
| `menu-bar` | `PanelTop` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/panel-top-Wu5KpjYN-5886bb6673e0.js` |
| `minus` | `minus-md-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `monitor` | `Monitor` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/monitor-DGEccXSZ-2ab19e425ce5.js` |
| `mosaic` | HelloX 细线像素格 | HelloX original | 20 单位画布，1.33 单位统一描边，无实心色块 | 本项目原创 |
| `move-up-right` | `arrow-up-right-lg-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-primary-6cd7b8b3f5e3.js` |
| `ocr-text` | `ScanText` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/scan-text-KcKEt7O4-4dad1d20ab7b.js` |
| `panel-top` | `sidebar-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `pin` | `pin-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `pipette` | `Pipette` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/pipette-BE_nXHrw-404397b8de58.js` |
| `play` | `play-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `plus` | `plus-lg-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `recording` | `record-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-primary-6cd7b8b3f5e3.js` |
| `redo-2` | `arrow-uturn-left-light-16` | Codex native | translate(16 0) scale(-1 1) | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `refresh-cw` | `arrows-clockwise-rotate-lg-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `scan-line` | `QrCode` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/qr-code-BuBaannF-bde39d4e9746.js` |
| `scroll-capture` | HelloX 滚动选区 | HelloX original | 20 单位画布，1.33 单位线宽 | 本项目原创 |
| `search` | `settings search / original 16-unit glyph` | Codex settings component | Original SVG geometry and 16 x 16 canvas; retains actual settings search optical size | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `settings` | `gear-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `sparkles` | `sparkles-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `square` | `square-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `table` | `table-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `triangle-alert` | `exclamation-mark-triangle-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `type` | `Type` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/type-Co2Qnl_R-3f798c087498.js` |
| `undo-2` | `arrow-uturn-left-light-16` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `upload` | `arrow-up-line-horizontal-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |
| `watermark` | `Droplet` | Codex bundled Lucide | Original geometry; stroke 2 -> 1.6 on the 24-unit canvas to match native Codex light optical width | `/webview/assets/droplet-DL7qoUmf-d4d38d057231.js` |
| `x` | `xmark-md-light-20` | Codex native | Original SVG geometry and canvas | `/webview/assets/app-initial-cadb12d4a15e.js` |

## 语义说明

- `app-window` 使用 Codex 应用快照窗口；`crosshair` 使用随包十字选区图形；`mosaic` 使用 HelloX 原创的细线像素格图形。
- `scroll-capture` 使用 HelloX 原创的纵向选区框与上下滚动箭头，`ocr-text` 使用扫描文字框，`scan-line` 使用可辨识二维码，`pipette` 使用滴管，`crop` 使用裁剪角，`watermark` 使用水滴。
- `local-translation` 与普通翻译使用同一个翻译图形，其本地属性由文字说明表达。
- 重做和向上展开仅镜像/旋转同系列原始方向图形，路径未经重绘。

原始静态应用包：`/Applications/ChatGPT.app/Contents/Resources/app.asar`。文件级 SHA-256 记录在构建参考 `build/ui-redesign/reference/full-icon-map.json`。
