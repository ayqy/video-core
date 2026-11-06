# 得意黑 Smiley Sans 离线封面字体

本目录保留未经修改的官方字体原件，仅作为视频封面中文标题字形；不安装或注册宿主字体，不作为正文/代码字体，不依赖系统已安装版本。

- 作者与权利人：atelierAnchor；Copyright (c) 2022--2024, atelierAnchor <https://atelier-anchor.com>。
- 官方说明：https://github.com/atelier-anchor/smiley-sans ；设计主页：https://atelier-anchor.com/typefaces/smiley-sans 。官方推荐用途包括平面海报、电商文案、视频标题、书报标题及游戏嵌入。
- 固定版本：[v2.0.1](https://github.com/atelier-anchor/smiley-sans/releases/tag/v2.0.1)，对应官方提交 `67e3821f4b06cbd7155fa6fa69daff4b6f311b76`。
- 原TTF：`SmileySans-Oblique.ttf`，2,629,764字节，SHA256 `b447d7e781f08bc95c4c9f23ba71ed2b8ebb639aa7184485c71c4ca5afcd25c4`。原字库PostScript名称为 `SmileySans-Oblique`，未子集化、转换、修字、变形或改名。
- 唯一官方发行附件为 [smiley-sans-v2.0.1.zip](https://github.com/atelier-anchor/smiley-sans/releases/download/v2.0.1/smiley-sans-v2.0.1.zip)，5,781,344字节，SHA256 `299c0be6c960ae37361762eca76f7d0cd516615435bb96c0d4b98a1e70178a07`。取得时仅在内存中校验该发行附件，再精确读取同名字体成员；仓库与交付产物未保存归档或其它字体格式。
- 完整许可：同目录 `LICENSE` 来自[固定官方提交的LICENSE原文](https://raw.githubusercontent.com/atelier-anchor/smiley-sans/67e3821f4b06cbd7155fa6fa69daff4b6f311b76/LICENSE)，4,422字节，SHA256 `9401f4050f1b66c26b6ccdc8b0e14a3c1cc37aac122eda84386f25854a9bec72`。原发行附件未含许可文本，因此另取同一提交的完整原文，不自行缩写或改写。

字体遵守 SIL Open Font License 1.1。保留名称为 `Smiley` 与 `得意黑`；本项目捆绑原字体，必须连同其版权和完整许可再分发，不可单独售卖字库。封面作品本身不因此必须使用OFL许可。

`scripts/embed_cover_typeface.py` 从上述固定原件生成 `Sources/VideoMedia/CoverTypeface.swift`：zlib level 9无损压缩、Base64文本内嵌，运行时在固定长度缓冲区内解压，同时校验压缩和原TTF摘要、完整流长度及PostScript名称，再直接通过 `CGDataProvider`、`CGFont`、`CTFontCreateWithGraphicsFont` 创建标题字体。Swift文件头保留完整原版权和OFL文本；无系统字体注册、文件路径、Bundle资源、网络下载或系统字体回退。

在仓库根目录执行 `python3 scripts/embed_cover_typeface.py` 可从原件重建；增加 `--check` 只核对生成字节是否一致，不改文件。封面默认通过 `CoverTypeface.font(size:)` 取得字体，其调用失败会明确报错，不换成其它字体。字体捆绑/字形技术验证不等同于最终封面设计通过。
