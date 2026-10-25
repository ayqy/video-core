# 连贯讲述配音

`expressive_tts.py`保留兼容文件名，当前使用固定的官方CosyVoice-300M-SFT模型和正常`inference_sft`入口，整段生成中文旁白，默认采用模型发布的`中文男`预设音色。可选音色以模型发布项和工具实际接受项为准。它不克隆人物，不调用云端TTS，也不在生成失败时改用旧声音。

当前SFT入口不提供显式语气或情绪控制。兼容参数`--instruction`只允许空串，非空内容连同纯空白都会明确拒绝，不会忽略后继续生成。文件名中的`expressive`不表示已交付情绪指令能力；朗读流畅度、语气是否自然及音色是否适合故事，仍须实际完整试听核验。

先写清故事和完整句段，再选预设音色并试听。不要为了字幕切分而在每个逗号处分别合成；同一景段内保留标点与连续语流。数字、术语等先走正常`speech normalize`并核对规范稿；此适配器不再次改写文案。每段最多240字，默认生成期限600秒，输出实长超过90秒会拒绝，不能自动截尾或加速来迁就原镜头。

## 本地准备

模型发布方为FunAudioLLM，模型及代码公开标注Apache-2.0：

- [SFT模型及权重](https://huggingface.co/FunAudioLLM/CosyVoice-300M-SFT/tree/fbb71de2afe387ed854eebd80b9f3d078c6b9869)
- [CosyVoice代码](https://github.com/FunAudioLLM/CosyVoice/tree/074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc)
- [Matcha-TTS依赖](https://github.com/shivammehta25/Matcha-TTS/tree/dd9105b34bf2be2230f4aa1e4769fb586a3c824e)

固定模型约2.3GB，另需Python环境与临时下载空间。当前配置面向Intel macOS、CPython3.11、CPU FP32；使用兼容Intel的Torch2.2.2，而非上游当前示例的Torch2.3.1。`cosyvoice-cpu-lock.txt`记录完整实际依赖。准备器只下载固定公开原件；训练、服务端和示例目录不导入。原件有大小或哈希差异就停止，不采用部分下载。

在自行选择的缓存目录准备环境，各阶段单独执行；`--python`传已安装的CPython3.11绝对路径，`--uv`传已有uv绝对路径：

```sh
python -B Integrations/prepare_cosyvoice.py --runtime .cache/narration-sft --python /path/to/python3.11 --uv /path/to/uv --stage source
python -B Integrations/prepare_cosyvoice.py --runtime .cache/narration-sft --python /path/to/python3.11 --uv /path/to/uv --stage model
python -B Integrations/prepare_cosyvoice.py --runtime .cache/narration-sft --python /path/to/python3.11 --uv /path/to/uv --stage environment
python -B Integrations/prepare_cosyvoice.py --runtime .cache/narration-sft --python /path/to/python3.11 --uv /path/to/uv --stage identity
```

准备阶段需要网络；生成阶段禁用网络、隐式HF令牌及遥测，且不读取服务凭据。缓存和权重不随工具分发。若已有Instruct环境，为SFT选择新的独立运行目录，保留旧原件与失败记录，不把旧模型或声音缓存冒充SFT。若准备失败，先看具体失败并改变条件；已安装或部分下载的目录不会被自动覆盖。

## 生成和复用

```sh
python -B Integrations/expressive_tts.py --runtime .cache/narration-sft --cache .cache/narration-sft/voices --text '四个邻居想修路。凑够三枚硬币，就能开工。' --voice 中文男 --seed 1986 --output narration.wav
```

相同文本、SFT模型、引擎源码、实际依赖、适配器、预设音色、正常SFT调用合同和种子命中同一缓存，并校验WAV与来源回执后复用；任一身份项改变就使用不同缓存。空的兼容`instruction`不会授予语气控制能力，旧Instruct调用也不能命中SFT缓存。缓存损坏会明确拒绝，不静默重生。并发同请求只允许一个生成作业；超时终止本作业进程组，不留下成功缓存或交付。模型推理子线程发生异常时，即使已返回部分非空音频，也会在写WAV前拒绝，不把部分语音发布或缓存。输出采用原子写入，不覆盖既有文件。

输出是22050Hz单声道PCM16及本地缓存中的`source.md`。它记录实际采样数和完整生成身份；没有伪造的字级时间戳。把真实音源、来源及许可通过正常素材导入和`speech attach`绑定到工程，按实长重新检查镜头、字幕和动作。更换配音后，旧声音、字幕和整片确认仍需重新核验。

适配器只向正常SFT入口传正文和模型发布的预设音色，不传语气提示或补任何指令边界标记。版本身份记录实际SFT调用合同，不能把Instruct模型、其它模型族或历史前端当作等价配置。生成声音还应独立核对是否多读、漏字或重复；ASR只能辅助核对朗读内容，调用成功、缓存哈希、文件格式或ASR文字一致均不能替代对流畅度、语气和音色的真实听审。

可复用音源及其来源可存入项目素材库；大型模型、依赖环境和过程日志保留在用户选择的缓存位置。合成模型的开源许可不代替具体素材、人物声纹或投稿渠道的适用权利核对。

`python -B -m unittest discover -s Integrations/tests -p test_expressive_tts.py`检查缓存、文件、并发和失败规则，不下载模型。测试声音是合成夹具，不能代替对真实旁白的流畅度、语气、音色及完整成片听审；实际听审通过之前，不应标记声音已确认。
