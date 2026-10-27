# 台湾女声朗读试听入口

`readaloud_tts.py`使用固定的第三方[edge-tts 7.3.1](https://pypi.org/project/edge-tts/7.3.1/)客户端访问Microsoft Edge消费者ReadAloud。它不是Azure Speech正式API，不需要读取账号凭据。本入口仅用于本地非商教学和管理员试听，不把接口可调用、客户端LGPLv3许可或生成成功当作音频商用、平台发布或人物声纹许可。

|编号|真实服务voice ID|目录属性|
|---|---|---|
|D|`zh-TW-HsiaoChenNeural`|Female / zh-TW / General / Friendly, Positive|
|E|`zh-TW-HsiaoYuNeural`|Female / zh-TW / General / Friendly, Positive|

这两个ID对应不同预置女声。它们的名称不承诺温柔甜美、性张力或更好的听感，最终须完整试听确认。不接受名人姓名、克隆参考音频、自定义角色、情感标记或未知声线，不把速度和音高变化当作新音色。`--rate`接受服务原生语速的规范整数百分比，范围`-50%`至`+100%`，默认`+0%`。负值在命令行使用单个参数形式，如`--rate=-10%`。必须带正负号，不接受`-0%`、前导零、小数、空白、无符号值或别名。`volume=+0%`、`pitch=+0Hz`保持固定。当前管理员优化调用仅验证D的`+6%`；其他速率只有请求边界规则验证，不代表音质或听审通过。

## 准备独立环境

本次固定依赖面向CPython3.10，带hash锁在`readaloud-cpu-lock.txt`。缓存、venv、下载原件及过程记录放在用户选择的临时运行目录，不随发行包分发。示例中的解释器应换成已安装的CPython3.10绝对路径；不自动下载Python，不使用Keychain或.NETRC凭据。

```sh
uv venv .cache/readaloud/venv --python /path/to/python3.10 --no-python-downloads
uv pip install --python .cache/readaloud/venv/bin/python --require-hashes --only-binary :all: --keyring-provider disabled --default-index https://pypi.org/simple -r Integrations/readaloud-cpu-lock.txt
```

另外保留未经改写的PyPI wheel到`.cache/readaloud/wheels/edge_tts-7.3.1-py3-none-any.whl`，大小38,908字节，SHA256为`2a3c79d6235a7a736d681233823ce5492e829b43eb47beae49aa181237a8f9a4`。通过固定版本[PyPI发布记录](https://pypi.org/pypi/edge-tts/7.3.1/json)中的wheel下载地址取得；下载后必须核大小和hash再使用。该记录只是公开下载索引，不是服务身份或密钥。

每次请求会核wheel原件、实际完整edge_tts源码与数据、锁中14项依赖的版本及各自安装载荷摘要、解释器和ffmpeg/ffprobe的版本/二进制摘要。仅记录涉及的依赖，不封存整个venv或冒用之前Qwen环境。`-I -B`隔离运行排除外部PYTHONPATH；网络子进程设置`NETRC=/dev/null`，只保已有代理路由且不记录其值。SSL使用原包的正常证书验证，不关闭校验。

## 生成完整原音

输入须为一段1–240字的完整正文，不接受控制字符、SSML或多段。转义后不超过原包4096字节单请求阈值；每声一次完整文本调用，不按字幕拆句合成。两声顺序执行，默认每声网络期限120秒，允许10–300秒，连接限10秒、单次接收最长60秒，父进程到期仅结束自有进程组。

```sh
python -B Integrations/readaloud_tts.py --runtime .cache/readaloud --cache .cache/readaloud/voices --allow-network --text '完整旁白原文' --voice zh-TW-HsiaoChenNeural --output d-original.mp3 --voice zh-TW-HsiaoYuNeural --output e-original.mp3
```

首次网络合成必须显式`--allow-network`，该选项授权把本次完整原文交给在线消费者朗读服务。语速参数完整传给服务正常SDK，由服务原生合成；它不改变声线ID，不代表一种新音色。SDK原样返回24kHz、48kbps、单声道MP3，输出保留原字节，不转WAV、不做后期调速变调或响度归一化。完整ffmpeg解码仅写内存检查，不生成替代音频。MP3实长须为0.2–90秒，解码采样有限、非静音；有损解码超过满幅的采样会如实记录，不能据此断言不可见服务母带的削波情况。

输出MP3旁同时写对应`.source.md`。来源记录完整原稿、voice ID、locale、本次语速及其余固定配置、客户端源码与实际依赖身份、原音hash、真实解码采样数及生成时间。服务没有披露远端模型版本或随机种子，均记`unknown_not_exposed_by_service`，不伪造可重现的模型版本。SDK错误只报告类别和合法HTTP状态码，不把可能含公开client token的请求URL写到输出或日志。

若需要小幅加快同一声线，使用同一完整正文、新输出路径，并显式传入`--rate +6%`。这会形成不同缓存身份，不能借用`+0%`缓存、覆盖原速原件或省略新请求的联网许可。每请求复制自己的配置，不修改全局默认或其他声线。

## 缓存与失败

缓存键绑定完整原稿、voice ID、locale、codec、本次语速及其余固定配置、客户端与实际依赖、解释器、适配器及检查工具。命中时重核原音与完整来源并再次全解码，只取回原字节，不发网络合成；因此缓存命中可不带`--allow-network`。不同原稿、依赖、源码或调用配置不命中同一缓存。

同请求缓存锁与运行目录批次锁避免重复提交。整批新声音全部通过技术检查后才提升成功缓存。第二声失败时，第一声和第二声实际返回的完整/部分原件均保留在`failed-batch-*`，不输出成成功候选，不回退旧声。缓存损坏、来源不符或身份漂移直接拒绝，不静默重生。原MP3和旁置来源均拒覆盖；发布中断时已验证缓存仍保留，可改用新输出路径重新取回，不宣称整批已交付。

工具不会更换工程默认音色，来源始终标记`listening_confirmed=false`、`commercial_allowed=false`、`upload_consent=false`。文字完整性、口音、情感与音色须真实完整试听；技术解码成功不能替代这些确认。选声后若要投入正式视频，应另核适用权利，并通过正常素材导入和`speech attach`按实际音长重新安排字幕与镜头。

```sh
python -B -m unittest discover -s Integrations/tests -p test_readaloud_tts.py
```

规则测试不联网。批次规则使用有限传输夹具，编解码规则只用本地生成的测试音，不把夹具或测试音当实际候选或听审证据。

参考：[Microsoft Edge朗读功能](https://support.microsoft.com/en-us/accessibility/edge/accessibility-features-in-microsoft-edge)、[第三方客户端及SSML限制](https://github.com/rany2/edge-tts#custom-ssml)。如改用Azure正式付费服务，须重新配置正常认证、客户端身份与适用条款，不能把本入口伪装为Azure服务。
