# 站酷快乐体 ZCOOL KuaiLe 离线封面标题字体

本目录保留未经修改的官方原TTF与完整SIL Open Font License 1.1。新封面使用粗犷、醒目的标题字形，并由脚本绘制描边与短距离立体字效；字体存在不等于管理员已认可封面效果。

- 官方发行来源：[Google Fonts固定提交](https://github.com/google/fonts/tree/6d49995f5d8f1c7d476760a580ffb89ce1e52c5d/ofl/zcoolkuaile)。上游项目为 https://github.com/googlefonts/zcool-kuaile 。
- 固定上游提交：`6d49995f5d8f1c7d476760a580ffb89ce1e52c5d`。
- 原件：`ZCOOLKuaiLe-Regular.ttf`，1,514,968字节，SHA256 `812a6fc1fe54b6d73a419245c32dfeba8aa33104d5be90d1cf6af082007cb71d`，PostScript名称 `ZCOOLKuaiLe-Regular`；未子集化、改名、转换、修字或变形。
- [完整官方OFL原文](https://github.com/google/fonts/blob/6d49995f5d8f1c7d476760a580ffb89ce1e52c5d/ofl/zcoolkuaile/OFL.txt)保存为同目录 `LICENSE`：4,398字节，SHA256 `538078469839b4a2e7ad22bef4ebe41681a4e53749bb2a072144024f1d6d703d`。
- 版权：Copyright 2018 The ZCOOL KuaiLe Project Authors (https://github.com/googlefonts/zcool-kuaile)。字体本身始终使用OFL，不随项目源码改为Apache-2.0；不得单独出售字库，随软件分发须保完整版权与许可。封面作品本身不因此必须采用OFL。

`scripts/embed_cover_typeface.py --display`从上述固定原件无损生成`Sources/VideoMedia/CoverDisplayTypeface.swift`，完整OFL保存在源码头；`--display --check`只逐字节核验可复现性。新API为`CoverTypeface.displayFont(size:)`，原得意黑`font(size:)`及默认生成输出保持兼容。

运行时直接通过固定字节创建CGFont与CTFont，校验压缩流、原字节长度、SHA256及PostScript名称，无系统字体注册、Bundle路径、网络下载或宿主字体依赖。缺字和加载失败必须明确拒绝，不静默换系统字库。公开包仅含本README、原TTF、完整LICENSE和内嵌源码；下载过程记录及上游METADATA不进入公开载荷。
