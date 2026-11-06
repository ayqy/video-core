# 抖音美好体 Bold 离线封面展示字体

本目录保留字节跳动官方发布的完整字体与 SIL Open Font License 1.1。标题采用原字形，不使用系统字体替代或合成粗体。

- 官方项目：[bytedance/fonts](https://github.com/bytedance/fonts)，由抖音品牌创意中心发布。
- 固定提交：`327565b61501d7a6d4902ed6ce417a7bd2ae54e6`。
- [原始 TTF](https://raw.githubusercontent.com/bytedance/fonts/327565b61501d7a6d4902ed6ce417a7bd2ae54e6/DouyinSans/DouyinSansBold.ttf)：`DouyinSansBold.ttf`，1,919,404 字节，SHA256 `fbecfacdfac33982774e301073a8d357a09c698cd3134bb6ddec0f5bfc268fa1`。
- 字体原有 PostScript 名称：`DOUYINSANSBOLD-GB`；family 为“抖音美好体”，style 为 `Bold`。原文件 OS/2 的 weightClass 为 400，不据此改造或合成字形。
- [原许可](https://raw.githubusercontent.com/bytedance/fonts/327565b61501d7a6d4902ed6ce417a7bd2ae54e6/DouyinSans/OFL.txt)在本目录以 `LICENSE` 原字节保存：4,455 字节，SHA256 `a6d5700a002ea32bcfbe3310253d603997683dac8ac63777e375d06c07c30ea6`。
- 版权及保留字体名称完整保留在 `LICENSE`。OFL 允许随软件嵌入、分发；字库本身不能单独出售，分发时须保留完整版权与许可。原 TTF 未子集化、改名、转换、修字或变形。

`python scripts/embed_cover_typeface.py --display` 从固定原件无损生成 `Sources/VideoMedia/CoverDisplayTypeface.swift`，源码头部保留完整许可，内嵌 zlib 压缩字节由硬长度、SHA256 与真实 PostScript 名称校验后直接建立 CGFont/CTFont；不查路径、Bundle 或系统字体，不注册字体。`--display --check` 核验逐字节可重现性。

`CoverTypeface.displayFont(size:)` 使用该原字库；原得意黑 `CoverTypeface.font(size:)`、默认生成器分支及既有生成结果保持兼容。根 `NOTICE` 同步携带本字体完整许可，供现有发布打包路径保留。

已用原 TTF 的 Unicode cmap 检查“豆子姐讲「囚徒困境」”“合作还是背叛？”“少一枚，路就修不成？”“公共品筹款”、A–Z、a–z、0–9 及常见中英标点，无缺字。这是有限字形覆盖检查，不代表全部中文或封面视觉效果已验收。
