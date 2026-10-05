#!/usr/bin/env bash
#
# 将目录下所有音乐文件制作成音乐 CD (CD-DA 红皮书标准)
# 用法: ./mkcd.sh [源目录] [选项]
#
# 功能:
#   1. 扫描目录中的音乐文件
#   2. 评估 CD 大小（总时长 / 占用容量 / 是否放得下）
#   3. 对 CD 中的曲目顺序排序
#   4. 用 ffmpeg 自动转换为 CD-DA 格式 (44.1kHz / 16bit / 立体声)
#   5. 生成 CUE 文件，用 cdrecord 刻录音频 CD 或打包成 ISO 镜像
#
# 选项:
#   -o, --output <目录>    WAV 输出目录 (默认: <源目录>/../cd_wav)
#   -s, --sort <方式>      排序: name | time | track | none (默认: name)
#   -c, --capacity <分钟>  CD 容量: 74 | 80 (默认: 80)
#   -d, --device <设备>    刻录机 (默认: /dev/sr0)
#   -i, --iso <文件>       生成 ISO 镜像文件，不刻录光盘
#   -b, --blank            刻录前先擦除 CD-RW
#   -n, --dry-run          只评估，不转换、不刻录
#   -k, --keep             保留中间 WAV 文件（默认刻录后删除）
#   -h, --help             显示本帮助
#
# 示例:
#   ./mkcd.sh 1                     # 用 1/ 目录的音乐制作 CD
#   ./mkcd.sh music -s track       # 按文件名中的曲目号排序
#   ./mkcd.sh 1 -c 74 -n           # 只评估 74 分钟 CD 是否放得下

set -u

# ---------------- 默认参数 ----------------
SRC_DIR=""
OUT_DIR=""
SORT_MODE="name"
CAPACITY=80
DEVICE="/dev/sr0"
ISO_PATH=""
BLANK=0
DRY_RUN=0
KEEP=0

# CD-DA 参数: 44100Hz × 2字节 × 2声道 = 176400 字节/秒
CDDA_BYTES_PER_SEC=176400

EXTS="mp3 flac ogg oga m4a aac wma opus ape wv aiff aif wav"

# ---------------- 帮助 ----------------
usage() {
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

# ---------------- 解析参数 ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output)   OUT_DIR="${2:-}"; shift 2 ;;
        -s|--sort)     SORT_MODE="${2:-}"; shift 2 ;;
        -c|--capacity) CAPACITY="${2:-}"; shift 2 ;;
        -d|--device)   DEVICE="${2:-}"; shift 2 ;;
        -i|--iso)      ISO_PATH="${2:-}"; shift 2 ;;
        -b|--blank)    BLANK=1; shift ;;
        -n|--dry-run)  DRY_RUN=1; shift ;;
        -k|--keep)     KEEP=1; shift ;;
        -h|--help)     usage ;;
        -*) echo "未知选项: $1" >&2; exit 1 ;;
        *)  SRC_DIR="$1"; shift ;;
    esac
done

if [ -z "$SRC_DIR" ]; then
    echo "错误: 请指定源目录" >&2
    usage
fi
if [ ! -d "$SRC_DIR" ]; then
    echo "错误: 目录不存在: $SRC_DIR" >&2
    exit 1
fi
case "$SORT_MODE" in
    name|time|track|none) ;;
    *) echo "错误: 排序方式必须是 name|time|track|none" >&2; exit 1 ;;
esac
case "$CAPACITY" in
    74|80) ;;
    *) echo "错误: CD 容量必须是 74 或 80 分钟" >&2; exit 1 ;;
esac

[ -z "$OUT_DIR" ] && OUT_DIR="$SRC_DIR/../cd_wav"

# ---------------- 1. 收集音乐文件 ----------------
echo "扫描目录: $SRC_DIR"
files=()
for ext in $EXTS; do
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$SRC_DIR" -maxdepth 1 -type f -iname "*.${ext}" -print0 2>/dev/null)
done

total=${#files[@]}
if [ "$total" -eq 0 ]; then
    echo "错误: 目录中没有找到音乐文件" >&2
    exit 1
fi
echo "找到 $total 个音乐文件"

# ---------------- 2. 排序 ----------------
# 生成 "排序键<TAB>文件路径" 列表，排序后再取回路径
sorted=()
while IFS= read -r line; do
    [ -n "$line" ] && sorted+=("${line#*$'\t'}")
done < <(
    for f in "${files[@]}"; do
        base="$(basename "$f")"
        case "$SORT_MODE" in
            name)  printf '%s\t%s\n' "$base" "$f" ;;
            time)  printf '%s\t%s\n' "$(stat -c %Y "$f")" "$f" ;;
            track) printf '%s\t%s\n' "$(printf '%s' "$base" | grep -oE '^[0-9]+' | awk '{printf "%04d", $1}')" "$f" ;;
            none)  printf '%s\t%s\n' "$base" "$f" ;;
        esac
    done | sort
)

# ---------------- 3. 评估 CD 大小 ----------------
echo "----------------------------------------"
echo "评估 CD 大小 (容量: ${CAPACITY} 分钟)"
echo "----------------------------------------"

cap_bytes=$((CAPACITY * 60 * CDDA_BYTES_PER_SEC))
total_sec=0
idx=0
for f in "${sorted[@]}"; do
    idx=$((idx + 1))
    dur="$(ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null)"
    dur="${dur%.*}"
    [ -z "$dur" ] && dur=0
    total_sec=$((total_sec + dur))
    printf '  %2d. %-40s %s\n' "$idx" "$(basename "$f")" "$(printf '%02d:%02d' $((dur/60)) $((dur%60)))"
done

total_bytes=$((total_sec * CDDA_BYTES_PER_SEC))
total_min=$((total_sec / 60))
total_sec_mod=$((total_sec % 60))
cap_mb=$((cap_bytes / 1024 / 1024))
total_mb=$((total_bytes / 1024 / 1024))

echo "----------------------------------------"
printf '总时长:   %d 分 %02d 秒\n' "$total_min" "$total_sec_mod"
printf '占用容量: %d MB (CD-DA 未压缩)\n' "$total_mb"
printf 'CD 容量:  %d MB (%d 分钟)\n' "$cap_mb" "$CAPACITY"
if [ "$total_bytes" -le "$cap_bytes" ]; then
    printf '评估结果: 可以刻录 (剩余 %d MB)\n' "$(((cap_bytes - total_bytes) / 1024 / 1024))"
    FIT=1
else
    printf '评估结果: 超出容量 %d MB，请减少曲目或使用 -overburn\n' \
        "$(((total_bytes - cap_bytes) / 1024 / 1024))"
    FIT=0
fi
echo "----------------------------------------"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "dry-run 模式: 不进行转换和刻录"
    exit 0
fi
mkdir -p "$OUT_DIR"
if [ "$FIT" -ne 1 ]; then
    echo "错误: 音乐总时长超出 CD 容量，已中止" >&2
    exit 1
fi

# ---------------- 4. ffmpeg 转换为 CD-DA WAV ----------------
echo "转换格式: 44.1kHz / 16bit / 立体声 (CD-DA)"
wavs=()
idx=0
for f in "${sorted[@]}"; do
    idx=$((idx + 1))
    base="$(basename "$f")"
    name="${base%.*}"
    out="$OUT_DIR/$(printf '%02d' "$idx") - $name.wav"

    # 已经是 CD-DA 格式的 WAV 直接复用，避免重复转换
    if [ "${base##*.}" = "wav" ]; then
        sr="$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate \
               -of csv=p=0 "$f" 2>/dev/null)"
        br="$(ffprobe -v error -select_streams a:0 -show_entries stream=bits_per_sample \
               -of csv=p=0 "$f" 2>/dev/null)"
        ch="$(ffprobe -v error -select_streams a:0 -show_entries stream=channels \
               -of csv=p=0 "$f" 2>/dev/null)"
        [ "$sr" = "44100" ] && [ "$br" = "16" ] && [ "$ch" = "2" ] && REUSE=1 || REUSE=0
    else
        REUSE=0
    fi
    if [ "$REUSE" -eq 1 ]; then
        echo "  [$idx/$total] 已是 CD-DA 格式，直接复用: $base"
        cp -- "$f" "$out"
    else
        echo "  [$idx/$total] 转换: $base"
        if ! ffmpeg -hide_banner -loglevel error -y -i "$f" -vn \
                    -acodec pcm_s16le -ar 44100 -ac 2 "$out" </dev/null; then
            echo "  失败: $base" >&2
            rm -f -- "$out"
            continue
        fi
    fi
    wavs+=("$out")
done

if [ "${#wavs[@]}" -eq 0 ]; then
    echo "错误: 没有成功转换任何文件" >&2
    exit 1
fi

# ---------------- 生成 CUE 文件 ----------------
cue="$OUT_DIR/cd.cue"
{
    echo "REM GENRE Mixed"
    echo "REM DATE $(date +%Y)"
    echo "PERFORMER \"Various\""
    echo "TITLE \"Music CD\""
    idx=0
    for w in "${wavs[@]}"; do
        idx=$((idx + 1))
        echo "FILE \"$(basename "$w")\" WAVE"
        echo "  TRACK $(printf '%02d' "$idx") AUDIO"
        echo "    INDEX 01 00:00:00"
    done
} > "$cue"
echo "已生成 CUE: $cue"

# ---------------- 5. 刻录 CD / 生成 ISO ----------------
if [ -n "$ISO_PATH" ]; then
    # 生成 ISO 镜像：把 WAV 音轨和 CUE 文件打包成标准 ISO 文件
    ISO_TOOL=""
    for tool in genisoimage mkisofs xorriso; do
        if command -v "$tool" >/dev/null 2>&1; then
            ISO_TOOL="$tool"
            break
        fi
    done
    if [ -z "$ISO_TOOL" ]; then
        echo "错误: 未找到 genisoimage / mkisofs / xorriso，无法生成 ISO" >&2
        exit 1
    fi

    # 转成绝对路径，避免在输出目录中执行时相对路径出错
    ISO_PATH="$(cd "$(dirname "$ISO_PATH")" && pwd)/$(basename "$ISO_PATH")"
    label="$(basename "$SRC_DIR")"
    [ -z "$label" ] && label="MKCD"

    echo "生成 ISO 镜像: $ISO_PATH ($ISO_TOOL)"
    iso_ok=0
    if [ "$ISO_TOOL" = "xorriso" ]; then
        ( cd "$OUT_DIR" && xorriso -as mkisofs -o "$ISO_PATH" -J -r -V "${label:0:32}" *.wav cd.cue ) && iso_ok=1
    else
        ( cd "$OUT_DIR" && "$ISO_TOOL" -o "$ISO_PATH" -J -r -V "${label:0:32}" *.wav cd.cue ) && iso_ok=1
    fi

    if [ "$iso_ok" -eq 1 ]; then
        echo "ISO 生成完成"
    else
        echo "ISO 生成失败" >&2
        exit 1
    fi
else
    if [ "$BLANK" -eq 1 ]; then
        echo "擦除 CD-RW ..."
        cdrecord -v dev="$DEVICE" blank=fast </dev/null
    fi

    echo "开始刻录到 $DEVICE ..."
    if cdrecord -audio -dao -v -pad dev="$DEVICE" "${wavs[@]}" </dev/null; then
        echo "刻录完成"
    else
        echo "刻录失败" >&2
        exit 1
    fi
fi

# ---------------- 清理 ----------------
if [ "$KEEP" -eq 0 ]; then
    rm -rf -- "$OUT_DIR"
    echo "已清理中间文件: $OUT_DIR"
else
    echo "保留中间文件: $OUT_DIR"
fi

echo "完成: 共 ${#wavs[@]} 首曲目"
