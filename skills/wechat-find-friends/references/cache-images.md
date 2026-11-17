# 微信缓存图片检索

## 先确认账号和范围

常见新版本 macOS 目录形状如下，实际位置必须发现并核对，不能取第一个账号目录：

```text
.../xwechat_files/<当前账号目录>/
├── msg/attach/<会话目录>/<月份>/Img/
└── cache/<月份>/Message/<会话目录>/Bubble 或 Thumb/
```

优先当前消息数据库给出的媒体路径及映射；其次按已经确认的会话目录检查。文件系统只提供候选时，保留归属未确认状态。

文件名可能带 `_t`、`_h`、`_b` 表示不同尺寸或用途，但不同缓存类型也可能另有命名。只在同会话、已验证的同一图片关系内合并版本；“去掉后缀同名”是发现候选的方法，不是无条件认定它们同图的证明。Bubble 可能只是裁剪预览。

缓存 mtime 是本地写入时间，不等于消息发送时间。按 mtime 窗口扫描可用于优先级检索，不能据此声称完整覆盖某段聊天日期。没有找到时检查这一限制及尚未映射的素材。

## atime 只作辅助线索

可在暂停其他源文件读取后，保存元数据快照 → 打开一个确定的会话或图片 → 再快照，以缩小目录候选。注意：

- 不同文件系统可能禁用或延迟更新 atime；微信已在内存缓存的图片也可能不再读盘。
- 哈希、解码、OCR 准备阶段读取原文件都会改变 atime。不要与该定位实验并发运行。
- 系统或微信后台读取也会产生噪声。无变化不代表没图片，有变化不代表已证明发送者。
- 将变化文件、观察窗口及其他可能读者记录下来；混入自身扫描的记录需剔除或重新采样，不能拿来改备注。

## 可复用的离线索引

`scripts/cache_image_index.py` 仅处理明确提供的文件清单，不发现密钥、不访问网络、不连接微信进程、不改微信目录。依赖 Pillow；读取 V1/V2 加密素材时还需要 PyCryptodome。使用环境已有 Python 依赖；缺失时说明，不静默安装或更改系统环境。

需单独准备环境时，使用虚拟环境安装 [scripts/requirements.txt](../scripts/requirements.txt) 中的依赖；ffmpeg 仅在处理 WXGF 时需要。不要把虚拟环境、图片密钥或生成的索引放入公开仓库。

先编译本机 OCR：

```sh
swiftc /path/to/wechat-find-friends/scripts/ocr_images.swift -o /task/ocr-images
```

建立清单；同一项的 `paths` 是经核实或待比较的图片版本。`conversation_ref` 和 `ownership` 只是调用者提供的线索，脚本不会替你验证联系人归属：

```json
[
  {
    "id": "image-001",
    "paths": ["/absolute/source/image.dat", "/absolute/source/image_t.dat"],
    "conversation_ref": "candidate-01",
    "ownership": "unconfirmed"
  }
]
```

```sh
python3 /path/to/wechat-find-friends/scripts/cache_image_index.py index \
  --manifest /task/images.json --out /task/image-index \
  --ocr-bin /task/ocr-images --workers 2

python3 /path/to/wechat-find-friends/scripts/cache_image_index.py find \
  --index /task/image-index --term '目标姓名' --term '目标院系' \
  --mode any --output /task/hits.json
```

多个词用 `any` 扩大线索召回，用 `all` 查询同一图片是否包含所有词。它们都是文字检索，不等于已经满足“本人发送、自我介绍”等身份条件。新线索直接重跑 `find`，无需重做 OCR；每次指定新的结果文件名，脚本不会覆盖已有输出。

每个图片项保留来源、SHA-256、原尺寸、OCR 行及置信度、处理错误和调用者提供的归属说明。处理一批就落盘。重新运行 `index` 会复用源路径、大小、mtime 和 OCR 配置一致的成功记录；失败项会重试。脚本不提供多个进程同时写同一个输出目录的支持。

`find` 会对照当前清单、索引配置和源文件元数据，跳过旧版本或已变化的记录，并输出 `coverage`：总项数、可检索项、未完成项和过期项。`index` / `find` 退出码 `3` 表示部分未完成，可用结果仍已保存；`2` 表示参数或环境错误；`0` 表示本次处理完整。零命中而覆盖不完整时只能报告“已读部分未命中”。即使 OCR 全部成功，缩略图清晰度和联系人归属仍须另核。旧格式索引用原清单重跑 `index` 后再查询。

索引目录含私人图片文字，保存在本次任务的私有本地目录。默认只短暂写 OCR 预览，随后逐项删除脚本自己生成的预览，保留文字索引。原文件始终只读；“清理微信缓存”不是本技能的一部分。

## 图片格式和清晰度

- 标准图片直接解码；旧 XOR 素材可凭文件头识别。
- V2 只使用已经取得的图片密钥文件，参数为 `--key-file /existing/key-info.json`，不把密钥值写进命令行。支持该文件中的 `image_aes_key` 与整数 `xor_key`；不会把密钥复制到索引。
- 当前支持的 V1/V2 布局有明确的头部和长度检查；不符合布局时记录 `unsupported`，不猜测或改写原数据。图片密钥与聊天数据库密钥不是一回事。
- 部分解码后数据是 WXGF。脚本可用已有 ffmpeg 从其中的 HEVC 数据读取首帧；这适合静态报名截图，不保证覆盖动画中的全部帧。失败时保留错误，不自动调用需要附加微信进程的转换器。离线方法参考[格式分析原文](https://sarv.blog/posts/wxam/)。
- 同一项的可读版本按实际像素面积选择，记录原尺寸。放大缩略图只方便 OCR，不会恢复已经丢失的笔画。
- 清晰原图缺失时，结果维持未知；不要用生成式超分辨率“补”姓名、学号或院系。

命中后再生成全尺寸预览核验：

```sh
python3 /path/to/wechat-find-friends/scripts/cache_image_index.py render \
  --record /task/image-index/records/RECORD_ID.json \
  --output /task/review.png
```

若源文件加密，`render` 同样提供既有 `--key-file`。渲染前会验证记录中的源文件摘要；文件变化时应重新建立索引。用图像查看工具确认文字，再回到会话归属与发送语境核验。
