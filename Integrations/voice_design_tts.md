# 独立成年女声候选

`voice_design_tts.py`使用固定官方Qwen3-TTS VoiceDesign模型，通过音色描述分别生成三种成年女声。它与旧`expressive_tts.py`预设入口独立，不修改工具默认音色。生成结果只是待试听的候选；管理员选定后，才在正常工程中选择对应音源，并重新核对声音、字幕与整片。

|编号|稳定设计ID|比较方向|
|---|---|---|
|A|`adult-warm-low`|成年低柔中音，轻微沙哑与气声，亲近、自信|
|B|`adult-bright-confident`|成年明亮中高音，轻快、有笑意和一点俏皮|
|C|`adult-soft-playful`|成年温润中音，成熟、从容、柔和；ID固定保留|

这些是设计目标，实际是否讨喜、有吸引力及差异是否足够，须完整试听。适配器不克隆或模仿特定人物，不把指令读入正文，不用后期变调冒充不同音色。

## 准备独立本地环境

模型为[官方Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign固定版本](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign/tree/5ecdb67327fd37bb2e042aab12ff7391903235d3)。固定包为[官方PyPI qwen-tts 0.1.1](https://pypi.org/project/qwen-tts/0.1.1/)，其wheel SHA256为`11a290d8dabc7ef91a90c54478c8ab19b3edb1d85c0882313721892bdc4af15d`。`voice-design-source.txt`列出完整18件包载荷摘要：17个Python源文件与官方`mel_filters.npz`数据。即使12Hz入口不使用25Hz滤波器，也保留并验证官方原件；适配器与清单共同限定源码和数据身份，不下载或执行模型仓库远程代码。

在用户选择的缓存目录准备`venv/bin/python`与`model/`。当前CPU方案使用CPython 3.10、`qwen-tts==0.1.1`、`torch==2.2.2`、`torchaudio==2.2.2`、`numpy==1.26.4`、`transformers==4.57.3`、`accelerate==1.12.0`、`numba==0.60.0`及`llvmlite==0.43.0`。后两项选择有Intel macOS发行wheel的版本，不能自由解析后在缺LLVM时反复尝试源码编译。其它依赖按实际安装完整封存；不要把旧CosyVoice环境改造成新模型环境。

`model/`只放固定版本的十二个原件：根目录下的`model.safetensors`、`README.md`、`config.json`、`generation_config.json`、`merges.txt`、`preprocessor_config.json`、`tokenizer_config.json`、`vocab.json`，以及`speech_tokenizer/`中的`model.safetensors`、`config.json`、`configuration.json`、`preprocessor_config.json`。从上面固定版本的官方`resolve`地址取得，保留原字节。模型约4.52GB，FP32推理还需模型参数及工作内存；依赖和下载临时空间另计。所有大小与SHA256由适配器逐件核验，缺件、多件、链接、错版本都拒绝，不采用半下载文件。

环境和原件准备完成后，显式封存一次：

```sh
python -B Integrations/voice_design_tts.py --runtime .cache/voice-design --seal-runtime
```

该步骤不加载模型或生成声音。它先核固定模型、官方引擎源码和关键依赖版本，再记录完整实际依赖、全部已安装依赖文件和解释器摘要。后续调用须逐字匹配`identity.txt`；缓存命中也重新核身份。首次封存是对当前准备环境的显式选择，不能通过覆盖旧封存把依赖漂移伪装成原环境；升级须另建环境，形成新缓存身份。模型许可不代替具体音源、人物或发布用途的权利核对。

## 一次载入，顺序生成三个完整音源

先写完整旁白并通过正常`speech normalize`核对数字、术语。以下`完整搭便车解说原稿`替换为同一完整正文，而不是某一句或六个片段：

```sh
python -B Integrations/voice_design_tts.py --runtime .cache/voice-design --cache .cache/voice-design/voices --text '完整搭便车解说原稿' --voice adult-warm-low --output candidate-a.wav --voice adult-bright-confident --output candidate-b.wav --voice adult-soft-playful --output candidate-c.wav
```

每个音色只调用一次正常`generate_voice_design(text=完整原文, language="Chinese", instruct=对应设计)`。一批只加载一个CPU模型，FP32、eager attention、四线程，随后按原序分别推理，不并发占用模型，也不把三条合并为大GPU批次。每项默认为seed 1986；显式`--seed`须逐项填写。完整原文、音色ID、设计指令、seed、生成参数、模型、源码、适配器、解释器与全部实际依赖共同决定缓存键。单项最多240字、实际音长0.2–90秒；超出就报错，不截尾、拼句或加速。

也可只传一个音色和输出。显式`--instruction`必须逐项等于代码中该稳定设计的完整说明；空串、纯空白、未知或错配指令均拒绝，不默默忽略。当前只接受固定VoiceDesign引擎与`Chinese`语言，不回退为CustomVoice、克隆模型、系统TTS或历史音源。

默认总期限10800秒，可用`--deadline`在5–14400秒内选择。生成过程禁网络、隐式HF令牌、遥测和外部Python路径，不读取服务凭据。引擎返回的一个完整单声道波形直接写为24000Hz PCM16，不作音高、速度、响度或片段加工；有限值、采样数、静音与削波核验失败就停止。技术核验不能证明每字都读对，也不能替代音色与情感的真实听审。

## 缓存、失败与工程使用

同一运行目录只允许一个生成进程；同一请求另有缓存锁。超时只终止该任务的进程组。完整批次通过核验前不提升新成功缓存；失败日志及已返回的原始/部分声音保留在所选缓存目录，失败声音不作为可命中缓存或交付。不要直接删除活跃作业的锁来再次加载模型。

缓存命中须核原WAV、完整来源回执与当前身份，损坏就拒绝，不静默重生。各输出以原子写入发布，不能覆盖已有文件；输出阶段若有磁盘故障，已发布的其它独立音源保持，尚未发布项可从已验证缓存另选新路径取回，不宣称整批成功。正常缓存里的`source.md`保完整身份和实际样本数，始终标记待试听，不提供伪造字级时间戳。

音色确定后，通过正常素材导入、`speech attach`和真实实长重排使用原音源；每条完整音频不是六段拼接，也不能通过改摘要继承旧声音/字幕审核。音色候选与来源可按用途留作素材，模型、依赖、过程日志保留在用户缓存位置，不打进发行包。向管理员发送时只寄明确请求的独立音频，不寄模型、日志或机器材料。

```sh
python -B -m unittest discover -s Integrations/tests -p test_voice_design_tts.py
```

该测试只检查参数、固定身份、进程边界、缓存、原子写入和失败规则；声音与引擎返回均为有限夹具，不能证明模型已真实运行，更不能当完整听审通过。
