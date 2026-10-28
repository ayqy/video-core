# 独立成年女声候选

`voice_design_tts.py`使用固定官方Qwen3-TTS VoiceDesign模型，通过原生音色描述生成独立成年女声候选。它与旧`expressive_tts.py`及D的ReadAloud入口独立，不修改工具默认音色。生成结果只是待试听的候选；管理员选定后，才在正常工程中选择对应音源，并重新核对声音、字幕与整片。

|编号|稳定设计ID|比较方向|
|---|---|---|
|A|`adult-warm-low`|成年低柔中音，轻微沙哑与气声，亲近、自信|
|B|`adult-bright-confident`|成年明亮中高音，轻快、有笑意和一点俏皮|
|C|`adult-soft-playful`|成年温润中音，成熟、从容、柔和；ID固定保留|
|独立新候选|`adult-taiwan-warm-narrative-v1`|成年台湾华语、温柔甜美的中音，按语义分组略停，突出关键动作和对比，停顿前干净收字，语气细腻有变化|

这些是设计目标，实际是否讨喜、有吸引力及差异是否足够，须完整试听。新候选不是D或原视频女声，不继承它们的认可，也不重复生成已拒绝的A/B/C。旧三设计的ID和完整指令保留。适配器不克隆或模仿特定人物，不把指令读入正文，不用后期变调冒充不同音色。

新设计通过模型实际支持的自然语言`instruct`提出台湾华语、语义分组、轻重和句尾收音要求；它不提供精确逐字停顿时长、SSML强调或口音保证。正文仍只放完整原稿，不插控制标签、不拆句重录。是否改善微停顿、重音、拖尾与语气，需要真实原音逐项听审；配置接入和规则通过不能证明听感已改善。

## 准备独立本地环境

模型为[官方Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign固定版本](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign/tree/5ecdb67327fd37bb2e042aab12ff7391903235d3)。固定包为[官方PyPI qwen-tts 0.1.1](https://pypi.org/project/qwen-tts/0.1.1/)，其wheel SHA256为`11a290d8dabc7ef91a90c54478c8ab19b3edb1d85c0882313721892bdc4af15d`。`voice-design-source.txt`列出完整18件包载荷摘要：17个Python源文件与官方`mel_filters.npz`数据。即使12Hz入口不使用25Hz滤波器，也保留并验证官方原件；适配器与清单共同限定源码和数据身份，不下载或执行模型仓库远程代码。

在用户选择的缓存目录准备`venv/bin/python`与`model/`。当前CPU方案使用CPython 3.10、`qwen-tts==0.1.1`、`torch==2.2.2`、`torchaudio==2.2.2`、`numpy==1.26.4`、`transformers==4.57.3`、`accelerate==1.12.0`、`numba==0.60.0`及`llvmlite==0.43.0`。后两项选择有Intel macOS发行wheel的版本，不能自由解析后在缺LLVM时反复尝试源码编译。其它依赖按实际安装完整封存；不要把旧CosyVoice环境改造成新模型环境。

正常准备入口为`prepare_voice_design.py`，当前只支持已验证的CPython **3.10.16 / Darwin x86_64**。它复用本适配器的固定模型身份及正常封存校验，不加载模型、不调用合成、不改CosyVoice环境。`voice-design-cpu-lock.txt`逐字节保留已记录的91项运行依赖，1550字节，SHA256为`3d0f9e64ed711773f2c29562ae3fb64f4e9dabf52b5aaf4801b22a543cb04894`；不允许自由换版本或增加源。基础解释器及uv须由调用者显式选定，实际版本和平台另行核对。

每阶段期限5–840秒，默认840秒，外层900秒批次另留退出清理时间。依赖和模型准备分阶段执行，不在生成worker中安装或下载。以下命令中的解释器、uv路径换成已经存在的绝对路径：

```sh
python3 -B Integrations/prepare_voice_design.py --runtime .cache/voice-design74 --stage environment --python /绝对路径/python3.10 --uv /绝对路径/uv --deadline 840
python3 -B Integrations/prepare_voice_design.py --runtime .cache/voice-design74 --stage model --file model.safetensors --deadline 840
python3 -B Integrations/prepare_voice_design.py --runtime .cache/voice-design74 --stage model --file speech_tokenizer/model.safetensors --deadline 840
python3 -B Integrations/prepare_voice_design.py --runtime .cache/voice-design74 --stage model --deadline 840
python3 -B Integrations/prepare_voice_design.py --runtime .cache/voice-design74 --stage seal --deadline 840
python3 -B Integrations/prepare_voice_design.py --runtime .cache/voice-design74 --stage verify --deadline 840
```

环境阶段只接受空venv或已装版本严格属于该91项的未封存部分环境；冲突、未知或重复依赖都拒绝。先以官方PyPI二进制包安装其中90项；[`sox==1.5.0`官方发行](https://pypi.org/pypi/sox/1.5.0/json)只有源码包，因此仅它作为明确例外：63905字节、SHA256 `12c7be5bb1f548d891fe11e82c08cf5f1a1d74e225298f60082e5aeb2469ada0`，固定公开原件通过核验后，用`setuptools==70.0.0`、`wheel==0.46.3`、`numpy==1.26.4`及`packaging==26.3`约束隔离构建。此构建不增加运行环境的91项；不开放其它源码包、额外索引或浮动构建版本。其它固定版本没有兼容wheel、安装失败或完整离线import失败，阶段都明确失败，不修改锁求通过。完整metadata最终须精确等于91项；实际import不调用`from_pretrained`。

准备前须保留10 GiB磁盘余量。环境阶段还预留尚缺模型原件及3 GiB环境、包缓存、下载和解包规划空间；3 GiB是准备预算，不是实测安装大小。模型阶段按所选原件的剩余字节预留，不另复制一份权重。低余量在安装、下载或创建新运行目录前停止，不删除现有最新数据。每个下载原位保留`.part`；续接须严格返回206和对应`Content-Range`，完整大小及SHA都正确后才原子提升。失败和超时保留原件及诊断，不冒准备成功、不从零盲目重下、不截断错误原件。

已有`identity.txt`后，环境、模型和seal阶段都拒绝写入；只允许verify按当前完整身份校验，或显式选择另一新缓存。准备锁与生成锁互斥；不删除活跃锁重开任务。模型取件只使用固定公开HTTPS地址，禁止降级重定向，不读取隐式服务Token、netrc或代理凭据。准备日志、依赖、模型和临时文件只留所选缓存，不进入发行包或管理员邮件。

模型下载默认直连。若受管运行环境的实际连接诊断表明直连超时，而本机已有可用的无账号公共网络路由，可显式加`--public-route-file`选择其普通文件路径；工具不会自动读取环境代理。该文件最多2048字节，只放一个有效UTF-8的HTTP(S)路由URL，不含账号、密码、空白、控制字符或末尾换行；须有主机、合法可选端口，路径只能为空或`/`，不能带query或fragment。文件、父链和硬链接均核验，不回显内容。此参数仅适用于model，环境/SoX下载、seal和verify不接受它。

```sh
python3 -B Integrations/prepare_voice_design.py --runtime .cache/voice-design74 --stage model --file model.safetensors --public-route-file .cache/voice-design74/public-route.txt --deadline 840
```

显式路由只改变固定HTTPS请求的连接路径，不修改模型来源、TLS证书和主机名验证、HTTPS重定向限制或完整size/SHA/Range条件。路由文件留所选缓存，不入库、不打进发行包，也不寄管理员；错误只报告类别和规则，不输出URL内容。

`model/`只放固定版本的十二个原件：根目录下的`model.safetensors`、`README.md`、`config.json`、`generation_config.json`、`merges.txt`、`preprocessor_config.json`、`tokenizer_config.json`、`vocab.json`，以及`speech_tokenizer/`中的`model.safetensors`、`config.json`、`configuration.json`、`preprocessor_config.json`。从上面固定版本的官方`resolve`地址取得，保留原字节。模型约4.52GB，FP32推理还需模型参数及工作内存；依赖和下载临时空间另计。所有大小与SHA256由适配器逐件核验，缺件、多件、链接、错版本都拒绝，不采用半下载文件。

环境和原件准备完成后，显式封存一次：

```sh
python -B Integrations/voice_design_tts.py --runtime .cache/voice-design --seal-runtime
```

该步骤不加载模型或生成声音。它先核固定模型、官方引擎源码和关键依赖版本，再记录完整实际依赖、全部已安装依赖文件和解释器摘要。后续调用须逐字匹配`identity.txt`；缓存命中也重新核身份。首次封存是对当前准备环境的显式选择，不能通过覆盖旧封存把依赖漂移伪装成原环境；升级须另建环境，形成新缓存身份。模型许可不代替具体音源、人物或发布用途的权利核对。

## 一次载入，按需生成一至三个完整音源

先写完整旁白并通过正常`speech normalize`核对数字、术语。以下`完整搭便车解说原稿`替换为同一完整正文，而不是某一句或六个片段：

```sh
python -B Integrations/voice_design_tts.py --runtime .cache/voice-design --cache .cache/voice-design/voices --text '完整搭便车解说原稿' --voice adult-taiwan-warm-narrative-v1 --output candidate-taiwan-v1.wav --deadline 750
```

每个音色只调用一次正常`generate_voice_design(text=完整原文, language="Chinese", instruct=对应设计)`。一批最多三个指定音色，只加载一个CPU模型，FP32、eager attention、四线程，随后按原序分别推理，不并发占用模型，也不把多条合并为大GPU批次。每项默认为seed 1986；显式`--seed`须逐项填写。完整原文、音色ID、设计指令、seed、生成参数、模型、源码、适配器、解释器与全部实际依赖共同决定缓存键。单项最多240字、实际音长0.2–90秒；超出就报错，不截尾、拼句或加速。

也可只传一个音色和输出。显式`--instruction`必须逐项等于代码中该稳定设计的完整说明；空串、纯空白、未知或错配指令均拒绝，不默默忽略。当前只接受固定VoiceDesign引擎与`Chinese`语言，不回退为CustomVoice、克隆模型、系统TTS或历史音源。

默认总期限10800秒，可用`--deadline`在5–14400秒内选择。生成过程禁网络、隐式HF令牌、遥测和外部Python路径，不读取服务凭据。引擎返回的一个完整单声道波形直接写为24000Hz PCM16，不作音高、速度、响度或片段加工；有限值、采样数、静音与削波核验失败就停止。技术核验不能证明每字都读对，也不能替代音色与情感的真实听审。

上述750秒仅为worker的有限尝试期限，不是完成时间保证；外层900秒批次还要留出前后完整身份校验和清理时间。历史CPU三段129字原稿总耗时3180.680秒，没有逐份耗时证据，不能据此断言一段在900秒内完成。超时按失败保留，不缩短原稿或降低完整性要求求通过。

## 缓存、失败与工程使用

同一运行目录只允许一个生成进程；同一请求另有缓存锁。超时只终止该任务的进程组。完整批次通过核验前不提升新成功缓存；失败日志及已返回的原始/部分声音保留在所选缓存目录，失败声音不作为可命中缓存或交付。不要直接删除活跃作业的锁来再次加载模型。

正常worker由主线程管理信号，非主线程调用在创建进程前明确拒绝。父进程收到SIGTERM会取消本次独立worker组，先TERM并最多等5秒，仍未退出再KILL并最多等5秒回收；子进程创建窗口中的取消先记录，取得本次进程后再清理，重复TERM不打断回收，退出时恢复原信号处理器。取消仍走原失败保全和锁释放，不提升成功缓存。该保证只覆盖可处理的父SIGTERM；父进程被SIGKILL、崩溃或宿主本身异常时，仍须宿主管理器按已知任务及进程身份兜底，不能由适配器声称已恢复宿主数据库或资源。

缓存命中须核原WAV、完整来源回执与当前身份，损坏就拒绝，不静默重生。各输出以原子写入发布，不能覆盖已有文件；输出阶段若有磁盘故障，已发布的其它独立音源保持，尚未发布项可从已验证缓存另选新路径取回，不宣称整批成功。正常缓存里的`source.md`保完整身份和实际样本数，始终标记待试听，不提供伪造字级时间戳。

适配器文件摘要也属于请求身份，新增设计会改变新适配器的缓存地址。旧A/B/C原音及回执继续保留，不把旧缓存改写成新请求，不重新生成已拒绝的音色补缓存，也不为新候选继承旧声音审核。

音色确定后，通过正常素材导入、`speech attach`和真实实长重排使用原音源；每条完整音频不是六段拼接，也不能通过改摘要继承旧声音/字幕审核。音色候选与来源可按用途留作素材，模型、依赖、过程日志保留在用户缓存位置，不打进发行包。向管理员发送时只寄明确请求的独立音频，不寄模型、日志或机器材料。

```sh
python -B -m unittest discover -s Integrations/tests -p test_voice_design_tts.py
python -B -m unittest discover -s Integrations/tests -p test_prepare_voice_design.py
```

该测试只检查参数、固定身份、进程边界、缓存、原子写入和失败规则；声音与引擎返回均为有限夹具，不能证明模型已真实运行，更不能当完整听审通过。
