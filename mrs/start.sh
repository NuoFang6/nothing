#!/bin/bash

# ==============================================================================
#                 自动化规则集生成与发布脚本 (孤儿分支版)
# ==============================================================================
#
# 功能:
# 1. 并行下载多个规则源。
# 2. 对规则进行格式化、去重和排序。
# 3. 使用 Mihomo 工具将规则转换为 .mrs 格式。
# 4. 将最终产物提交到一个独立的孤儿分支，保持主分支历史干净。
#
# by [您的聪慧猫娘助手]
#

set -e          # 任何命令失败则立即退出脚本
set -o pipefail # 管道中的任何命令失败，都视为整个管道失败

# ================ 配置部分 ================
# 获取脚本所在的绝对目录，确保路径在任何地方执行都正确
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# 工作目录设置 (用于存放临时文件和下载的工具)
WORK_DIR="${SCRIPT_DIR}/tmp"
# Git 仓库的本地路径
REPO_DIR="${SCRIPT_DIR}/../nothing" # 假设仓库在脚本所在目录的上一级
# 产物输出目录 (在规则处理阶段使用)
OUTPUT_DIR="${WORK_DIR}/output/mrs"
# 孤儿分支的名称
ORPHAN_BRANCH="rules-autoupdate"

# ================ 数据处理函数 ================
# 移除注释和空行
remove_comments_and_empty() {
    sed '/^#/d; /^$/d;'
}

# 确保文件以换行符结束
ensure_trailing_newline() {
    sed -e '$a\'
}

# 添加前缀和后缀（可自定义）
add_prefix_suffix() {
    local prefix="${1:-  - \'}"
    local suffix="${2:-\'}"
    sed "s/^/$prefix/; s/$/$suffix/"
}

# 为pihole格式添加特定前缀（+.）
format_pihole() {
    add_prefix_suffix "  - '+." "'"
}

# 标准yaml列表格式化
format_yaml_list() {
    add_prefix_suffix "  - '" "'"
}

# 移除重复行并排序，确保结果唯一 (核心优化)
remove_duplicates() {
    sort -u
}

# ================ 数据源配置 ================
# 使用更清晰的关联数组来配置源，方便扩展
# 格式: [规则名]="类型 格式 源1|处理命令 源2|处理命令 ..."
declare -A RULE_SETS
RULE_SETS=(
    ["ad"]="domain yaml https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-clash.yaml|remove_comments_and_empty \
                         https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-httpdns-cn@ads.list|remove_comments_and_empty|format_yaml_list \
                         https://github.com/ignaciocastro/a-dove-is-dumb/raw/refs/heads/main/pihole.txt|remove_comments_and_empty|format_pihole"
    ["cn"]="domain text https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/cn.list \
                       https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/steam@cn.list \
                       https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft@cn.list \
                       https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google@cn.list \
                       https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/win-update.list \
                       https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/private.list"
    ["cnIP"]="ipcidr text https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cn.list \
                         https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.list"
)

# ================ 工具函数 ================
# 检查依赖项
check_dependencies() {
    echo "喵~ 正在检查环境依赖..."
    local missing_deps=()
    for cmd in curl wget jq git gunzip sudo; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "错误：主人，缺少必要的依赖项: ${missing_deps[*]}" >&2
        echo "请先安装它们再运行脚本哦~" >&2
        exit 1
    fi
    echo "依赖项都齐全啦！"
}

# 初始化环境
init_env() {
    echo "正在初始化环境..."
    # 修改时区 (如果不需要或没有权限，可以注释掉这一行)
    # sudo timedatectl set-timezone 'Asia/Shanghai'

    # 创建工作目录和产物输出目录
    mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

    # 下载最新 mihomo (仅在不存在时下载)
    if [ ! -f "${WORK_DIR}/mihomo" ]; then
        echo "下载Mihomo工具..."
        cd "$WORK_DIR" || exit 1
        local download_url
        download_url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases |
            jq -r '.[] | select(.tag_name | test("Prerelease-Alpha")) |
                     .assets[] | select(.name | test("mihomo-linux-amd64-alpha-.*.gz")) |
                     .browser_download_url' | head -1)

        if [ -z "$download_url" ]; then
            echo "错误：无法获取Mihomo下载链接" >&2
            exit 1
        fi

        wget -q -O mihomo.gz "$download_url"
        gunzip mihomo.gz
        chmod +x mihomo
        cd "$SCRIPT_DIR" || exit 1
    else
        echo "Mihomo工具已存在，跳过下载。"
    fi

    echo "环境初始化完成！"
}

# (已优化) 并行处理规则并转换为MRS格式
process_ruleset_parallel() {
    local name=$1
    local type=$2
    local format=$3
    shift 3 # 将前三个参数移出，剩下的就是sources
    local sources=("$@")

    echo "处理 $name 规则集..."

    # 创建临时目录存放下载的源文件
    local temp_dir="${WORK_DIR}/${name}_temp"
    mkdir -p "$temp_dir"

    local i=0
    local pids=()
    for source_info in "${sources[@]}"; do
        # 安全地解析源信息
        IFS="|" read -r url process_cmd_str <<<"$source_info"
        local old_ifs="$IFS"

        local temp_file="${temp_dir}/${i}_$(basename "$url" | tr -d '@.')"

        ( # --- 开始后台子进程 ---
            echo "  [${name}] 下载: $(basename "$url")"
            # 下载内容到变量
            local content
            content=$(wget -q -O - "$url")
            if [ $? -ne 0 ]; then
                echo "警告：下载 $url 失败" >&2
                # 创建空文件以防后续步骤失败
                >"$temp_file"
                exit 0 # 正常退出子进程
            fi

            # 安全地处理管道命令 (告别eval!)
            local stream="$content"
            if [ -n "$process_cmd_str" ]; then
                IFS='|' read -ra cmds <<<"$process_cmd_str"
                for cmd in "${cmds[@]}"; do
                    stream=$(echo "$stream" | "$cmd")
                done
            else
                # 默认处理
                stream=$(echo "$stream" | remove_comments_and_empty)
            fi

            echo "$stream" | ensure_trailing_newline >"$temp_file"
        ) &
        pids+=($!)
        let i++
        IFS="$old_ifs" # 恢复IFS
    done

    # 等待所有下载和初步处理完成
    echo "等待 $name 的所有源文件处理完成..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # 合并、去重、转换
    local combined_file="${WORK_DIR}/${name}.all"
    local final_ext=$([[ "$format" == "yaml" ]] && echo "yaml" || echo "text")
    local final_file="${WORK_DIR}/${name}.${final_ext}"
    local mrs_file="${WORK_DIR}/${name}.mrs"

    echo "合并和转换 $name 规则集..."
    # cat所有临时文件，确保顺序正确
    cat "${temp_dir}"/* >"$combined_file"

    # 核心处理：去重、移除最终的空行
    cat "$combined_file" | remove_duplicates | sed '/^$/d' >"$final_file"

    # 使用 mihomo 转换
    "${WORK_DIR}/mihomo" convert-ruleset "$type" "$final_ext" "$final_file" "$mrs_file"

    # 将最终产物移动到输出目录
    mv -f "$final_file" "$mrs_file" "$OUTPUT_DIR/"

    # 清理临时文件
    rm -rf "$temp_dir" "$combined_file"

    echo "$name 规则集处理完成！"
}

# (全新) 提交更改到孤儿分支
commit_changes() {
    echo "正在将产物提交到孤儿分支 '$ORPHAN_BRANCH'..."

    cd "$REPO_DIR" || {
        echo "错误：仓库目录 $REPO_DIR 不存在" >&2
        exit 1
    }

    git config --local user.email "actions@github.com"
    git config --local user.name "GitHub Actions (Rule Updater)"

    # 切换到孤儿分支，如果远程不存在，会基于本地创建一个
    # 如果本地也不存在，则创建一个全新的
    git checkout "$ORPHAN_BRANCH" 2>/dev/null || git checkout --orphan "$ORPHAN_BRANCH"

    # 获取远程分支的最新状态
    git fetch origin "$ORPHAN_BRANCH" &>/dev/null
    # 将本地分支强制重置为远程状态，确保从最新状态开始
    git reset --hard "origin/${ORPHAN_BRANCH}" &>/dev/null

    # 清理当前工作目录，准备迎接新文件
    # 使用 find 和 xargs 可以安全地处理大量文件
    find . -maxdepth 1 ! -name '.git' ! -name '.' ! -name '..' -exec rm -rf {} +

    # 将所有最终产物从工作目录移动到仓库根目录
    echo "正在移动产物到仓库..."
    mv "$OUTPUT_DIR"/* .

    # 添加所有新文件
    git add .

    # 检查是否有文件变动
    if git diff --staged --quiet; then
        echo "规则文件没有变化，无需提交。喵~"
        return 0
    fi

    # 创建一个全新的提交
    # 在孤儿分支上，每次都是一个全新的历史，所以直接 commit 即可
    local commit_message="[Auto] Update rules on $(date -u +'%Y-%m-%d %H:%M:%S %Z')"
    git commit -m "$commit_message"

    # 强制推送到远程孤儿分支，用新历史覆盖旧历史
    echo "正在强制推送到远程分支 '$ORPHAN_BRANCH'..."
    git push -u origin "$ORPHAN_BRANCH" --force

    echo "产物已成功发布到 '$ORPHAN_BRANCH' 分支！"
}

# ================ 主执行流程 ================
main() {
    check_dependencies
    init_env

    # 清理旧的产物目录，以防万一
    rm -rf "$OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"

    local pids=()
    # 使用关联数组循环启动并行任务
    for name in "${!RULE_SETS[@]}"; do
        # 将字符串配置解析为数组
        read -r type format sources_str <<<"${RULE_SETS[$name]}"
        # https://stackoverflow.com/a/10586169/2790933
        IFS=" " read -r -a sources_array <<<"$sources_str"

        process_ruleset_parallel "$name" "$type" "$format" "${sources_array[@]}" &
        pids+=($!)
    done

    # 等待所有处理完成
    echo "等待所有规则集处理任务完成..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    echo "所有规则集均已处理完毕！"

    # 提交更改
    commit_changes

    # 清理整个工作目录
    echo "清理临时工作目录..."
    rm -rf "$WORK_DIR"

    echo "所有操作已圆满完成！主人辛苦啦~ Nya~"
}

# 执行主函数
main
