# 我的音乐CD (MyMusicCD)

音乐 CD 制作工具，支持将各种音频格式转换为 CD-DA 标准格式并刻录成光盘或生成 ISO 镜像。

## 功能特性

- **音频格式转换** — 使用 ffmpeg 自动将 MP3、FLAC、OGG、M4A、AAC 等格式转换为 CD-DA 标准 (44.1kHz / 16bit / 立体声)
- **CD 容量评估** — 实时评估音乐总时长是否超出 CD 容量 (74 / 80 分钟)
- **曲目排序** — 支持按文件名、时间、曲目号排序，也可手动拖拽调整
- **CUE 文件生成** — 自动生成标准 CUE 表文件
- **光盘刻录** — 使用 cdrecord 刻录音频 CD，支持 CD-RW 擦除
- **ISO 镜像** — 支持生成 ISO 镜像文件，无需刻录机
- **图形界面** — 基于 Flutter 的 Linux 桌面 GUI，操作直观
- **命令行工具** — 提供 shell 脚本，适合批量处理和自动化

## 项目结构

```
MakeCD/
├── MyMusicCD/          # Flutter GUI 应用
│   ├── lib/            # Dart 源码
│   │   ├── main.dart   # 主界面
│   │   ├── models/     # 数据模型 (project.dart, track.dart)
│   │   └── services/   # 服务层 (cd_service.dart, native_file_dialog.dart, output_dir.dart)
│   ├── assets/         # 图标资源
│   └── linux/          # Linux 平台配置
├── mkcd.sh             # 命令行 CD 制作脚本
├── bld.sh              # 一键打包脚本 (编译 + deb + tar.gz)
└── dist/               # 打包输出目录
```

## 安装

### 方式一：deb 安装包 (推荐)

```bash
sudo dpkg -i dist/mymusiccd_1.0.0+1_amd64.deb
```

安装后可在应用菜单中启动，或命令行运行 `MyMusicCD`。

### 方式二：绿色版 (tar.gz)

```bash
tar -xzf dist/MyMusicCD-1.0.0+1-linux-x64.tar.gz
cd MyMusicCD-1.0.0+1-linux-x64
./MyMusicCD
```

### 运行依赖

| 依赖 | 用途 |
|------|------|
| GTK 3 (libgtk-3-0) | GUI 界面 |
| ffmpeg / ffprobe | 音频格式转换 |
| cdrecord (wodim) | CD 刻录 |
| genisoimage / mkisofs / xorriso | ISO 镜像生成 (可选) |

## 使用方法

### GUI 模式

1. 启动应用后，点击右上角菜单 **新建项目** 或 **打开项目**
2. 点击 **新增音频文件** 或 **导入目录中所有音频文件** 添加音轨
3. 使用上下箭头调整曲目顺序，或删除不需要的音轨
4. 选择 CD 容量和刻录机
5. 点击 **转换并刻录** 或 **生成 ISO 镜像**

### 命令行模式

```bash
# 基本用法：将目录中的音乐制作成 CD
./mkcd.sh /path/to/music

# 按曲目号排序，指定 74 分钟 CD
./mkcd.sh /path/to/music -s track -c 74

# 只评估容量，不转换不刻录
./mkcd.sh /path/to/music -n

# 生成 ISO 镜像而非刻录
./mkcd.sh /path/to/music -i output.iso

# 刻录前擦除 CD-RW
./mkcd.sh /path/to/music -b

# 保留中间 WAV 文件
./mkcd.sh /path/to/music -k
```

#### 命令行选项

| 选项 | 说明 |
|------|------|
| `-o, --output <目录>` | WAV 输出目录 (默认: `<源目录>/../cd_wav`) |
| `-s, --sort <方式>` | 排序方式: `name` / `time` / `track` / `none` |
| `-c, --capacity <分钟>` | CD 容量: `74` / `80` (默认: 80) |
| `-d, --device <设备>` | 刻录机设备 (默认: `/dev/sr0`) |
| `-i, --iso <文件>` | 生成 ISO 镜像，不刻录 |
| `-b, --blank` | 刻录前擦除 CD-RW |
| `-n, --dry-run` | 只评估，不转换不刻录 |
| `-k, --keep` | 保留中间 WAV 文件 |

## 从源码构建

### 前置要求

- [Flutter](https://docs.flutter.dev/get-started/install) SDK >= 3.11.5
- Linux 桌面开发依赖 (`libgtk-3-dev` 等)

### 编译运行

```bash
cd MyMusicCD
flutter pub get
flutter run -d linux
```

### 打包发布

```bash
./bld.sh
```

打包脚本会自动完成：
1. 编译 Flutter Linux Release 版本
2. 制作 deb 安装包 (含桌面菜单项和图标)
3. 制作 tar.gz 绿色版压缩包

产物输出到 `dist/` 目录。

## 技术细节

- **CD-DA 标准**: 44100Hz 采样率 × 16bit 位深 × 2 声道 = 176,400 字节/秒
- **容量计算**: 80 分钟 CD ≈ 806 MB，74 分钟 CD ≈ 747 MB
- **音频转换**: 已是 CD-DA 格式的 WAV 文件直接复用，避免重复转换
- **临时文件**: 中间 WAV 和 CUE 文件在刻录/生成 ISO 后自动清理
