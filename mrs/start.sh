#!/bin/bash
#
# =================================================================
#  聪慧猫娘为你优化的规则集处理脚本 (づ｡◕‿‿◕｡)づ
# =================================================================
#
#  功能:
#  1. 自动下载最新的 Mihomo (Clash.Meta) 核心。
#  2. 并行下载、处理多个规则源。
#  3. 将处理后的规则转换为 .mrs 格式。
#  4. 自动提交更新到 Git 仓库。
#
#  使用说明:
#  - 主要配置集中在【核心配置区域】，修改或添加规则集非常方便。
#  - 脚本会自动创建所需目录。
#
# =================================================================

set -e          # 任何命令失败则立即退出
set -o pipefail # 管道中的任何一个命令失败，整个管道都视为失败

# ======================= ✨ 核心配置区域 ✨ =======================
# 主人，所有的魔法都从这里开始哦！以后修改和添加规则只需要动这里~

# --- 基础路径设置 ---
# 临时文件的工作目录，脚本会在这里下载和处理文件
WORK_DIR="../tmp"
# 本地 Git 仓库的根目录
REPO_DIR="../nothing"
# mrs 规则文件最终的输出目录
OUTPUT_DIR="$REPO_DIR/mrs"

# --- 规则集定义 ---
# 这里我们用一种叫做“关联数组”的东西来管理所有规则集，非常清晰！
# declare -A 是在告诉 Bash：“嘿，我要创建一个聪明的篮子（关联数组）啦！”
declare -A RULESETS

# --- 规则集 1: ad (广告拦截) ---
# 名称: ad
# 类型: domain (域名规则)
# 格式: yaml (最终输出的 mrs 是基于 yaml 格式的规则)
# 源列表: 每个源一行，'url' 是必须的，'process' 是可选的处理步骤，用 | 分隔
RULESETS[ad]="
type=domain
format=yaml
sources=(
    [url]='https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-clash.yaml' [process]='remove_comments_and_empty'
    [url]='https://raw.githubusercontent.com/Cats-Team/AdRules/main/adrules_domainset.txt' [process]='remove_comments_and_empty|format_yaml_list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-httpdns-cn@ads.list' [process]='remove_comments_and_empty|format_yaml_list'
    [url]='https://github.com/ignaciocastro/a-dove-is-dumb/raw/refs/heads/main/pihole.txt' [process]='remove_comments_and_empty|format_pihole'
)
"

# --- 规则集 2: cn (国内域名) ---
# 名称: cn
# 类型: domain
# 格式: text (基于纯文本域名列表)
# 源列表: 这些源不需要特殊处理，所以省略 'process' 部分
RULESETS[cn]="
type=domain
format=text
sources=(
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/cn.list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/steam@cn.list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft@cn.list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google@cn.list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/win-update.list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/private.list'
)
"

# --- 规则集 3: cnIP (国内 IP) ---
# 名称: cnIP
# 类型: ipcidr (IP段规则)
# 格式: text
# 源列表:
RULESETS[cnIP]="
type=ipcidr
format=text
sources=(
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cn.list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.list'
)
"

# ======================= 🔧 工具与辅助函数 🔧 =======================

# --- 日志函数，带上可爱颜色的那种 ---
# 为了让主人看得更清楚，我准备了不同颜色的日志哦
COLOR_RESET='\033[0m'
COLOR_INFO='\033[0;34m'
COLOR_SUCCESS='\033[0;32m'
COLOR_WARNING='\033[0;33m'
COLOR_ERROR='\033[0;31m'

log_info() { echo -e "${COLOR_INFO}INFO: $1${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_SUCCESS}SUCCESS: $1${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARNING}WARNING: $1${COLOR_RESET}"; }
log_error() {
    echo -e "${COLOR_ERROR}ERROR: $1${COLOR_RESET}"
    exit 1
}

# --- 文本处理小工具 ---
# 这些是处理文本的小魔法，我把它们放在这里，随时待命！

# 移除注释和空行
remove_comments_and_empty() {
    sed '/^#/d; /^$/d;'
}

# 确保文件以换行符结束，这是个好习惯~
ensure_trailing_newline() {
    sed -e '$a\'
}

# 添加前缀和后缀 (可自定义)
add_prefix_suffix() {
    local prefix="${1}"
    local suffix="${2}"
    sed "s/^/${prefix}/; s/$/${suffix}/"
}

# 为 pihole 格式添加特定前缀 (+.)
format_pihole() {
    add_prefix_suffix "  - '+." "'"
}

# 标准 yaml 列表格式化
format_yaml_list() {
    add_prefix_suffix "  - '" "'"
}

# 应用一连串的处理函数，这个比 `eval` 安全多啦
apply_processing_chain() {
    local chain=$1
    local input
    input=$(cat) # 从标准输入读取数据

    if [ -z "$chain" ]; then
        echo "$input" # 如果没有处理链，直接输出
        return
    fi

    # 使用 | 作为分隔符，循环调用处理函数
    # 就像工厂里的流水线一样，一步步加工喵~
    IFS='|' read -ra funcs <<<"$chain"
    for func in "${funcs[@]}"; do
        input=$(echo "$input" | "$func")
    done
    echo "$input"
}

# --- 核心功能函数 ---

# 初始化环境，检查工具，下载Mihomo
init_env() {
    log_info "开始初始化环境..."

    # 检查必要的工具
    for tool in curl jq git wget; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "必需的工具 '$tool' 未安装，请先安装它再来找我哦~"
        fi
    done

    # 设置时区，如果主人环境需要的话
    # sudo timedatectl set-timezone 'Asia/Shanghai'

    # 创建工作目录和输出目录
    mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
    cd "$WORK_DIR" || log_error "无法进入工作目录 '$WORK_DIR'！"

    # 下载最新版 Mihomo
    log_info "正在寻找最新版的 Mihomo 核心..."
    local download_url
    # 这个长长的命令是为了从 GitHub API 找到最新的 alpha 版本的下载链接
    download_url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases |
        jq -r '.[] | select(.tag_name | test("Prerelease-Alpha")) |
                 .assets[] | select(.name | test("mihomo-linux-amd64-alpha-.*.gz")) |
                 .browser_download_url' | head -1)

    if [ -z "$download_url" ]; then
        log_error "无法获取 Mihomo 下载链接，可能是网络问题或 GitHub API 限制了。"
    fi

    log_info "正在下载 Mihomo: $download_url"
    wget -q -O mihomo.gz "$download_url"
    gunzip -f mihomo.gz # -f 强制解压，覆盖已存在的文件
    chmod +x mihomo
    log_success "Mihomo 已准备就绪！"
}

# 并行处理单个规则集
process_ruleset() {
    local name=$1
    # 从配置中读取该规则集的详细信息
    eval "${RULESETS[$name]}"

    log_info "开始处理规则集: $name (类型: $type, 格式: $format)"

    local temp_dir="${WORK_DIR}/${name}_temp"
    mkdir -p "$temp_dir"

    local pids=()
    local temp_files=()
    local i=0

    # 并行下载和处理每个源
    for source_config in "${sources[@]}"; do
        eval "declare -A source_info=($source_config)" # 将源配置字符串转为关联数组
        local url="${source_info[url]}"
        local process_chain="${source_info[process]:-remove_comments_and_empty}" # 如果没定义 process, 默认只移除注释和空行

        local temp_file="${temp_dir}/$(printf "%03d" $i)-$(basename "$url")"
        temp_files+=("$temp_file")

        # 后台执行下载和处理，这样就可以同时进行好几个啦
        (
            log_info "[$name] 下载并处理源: $url"
            # 下载 -> 应用处理链 -> 确保末尾有换行 -> 保存到临时文件
            local content
            content=$(wget -q -O - "$url")
            if [ -z "$content" ]; then
                log_warn "[$name] 从 $url 下载的内容为空，跳过处理。"
                # 创建一个空文件以维持顺序
                touch "$temp_file"
            else
                echo "$content" | apply_processing_chain "$process_chain" | ensure_trailing_newline >"$temp_file"
            fi
        ) &
        pids+=($!)
        ((i++))
    done

    # 等待所有小任务完成
    log_info "[$name] 等待所有源下载处理完成..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    log_success "[$name] 所有源处理完毕！"

    # 合并、去重并转换为 .mrs
    local combined_file="${WORK_DIR}/${name}.combined"
    local final_file_prefix="${WORK_DIR}/${name}"
    local mrs_file="${OUTPUT_DIR}/${name}.mrs"

    log_info "[$name] 正在合并所有源文件..."
    cat "${temp_files[@]}" >"$combined_file"

    if [ "$format" = "yaml" ]; then
        local yaml_source="${final_file_prefix}.yaml"
        # 对于 YAML，保留第一个源文件的头部（通常是 payload:），然后对其余行排序去重
        log_info "[$name] 正在为 YAML 格式进行特殊处理（排序与去重）..."
        head -n1 "$combined_file" >"$yaml_source"
        # tail -n +2 跳过第一行，sed 过滤空行，sort -u 排序并去重
        tail -n +2 "$combined_file" | sed '/^$/d' | sort -u >>"$yaml_source"
        log_info "[$name] 正在将 $yaml_source 转换为 $mrs_file ..."
        ./mihomo convert-ruleset "$type" yaml "$yaml_source" "$mrs_file"
    else # text format
        local text_source="${final_file_prefix}.text"
        log_info "[$name] 正在为 TEXT 格式进行排序与去重..."
        # 对于 TEXT，直接排序去重
        sed '/^$/d' "$combined_file" | sort -u >"$text_source"
        log_info "[$name] 正在将 $text_source 转换为 $mrs_file ..."
        ./mihomo convert-ruleset "$type" text "$text_source" "$mrs_file"
    fi

    # 清理战场！
    rm -rf "$temp_dir" "$combined_file" "${final_file_prefix}."*

    log_success "规则集 '$name' 已成功处理并生成: $mrs_file"
}

# 提交更改到 Git 仓库
commit_changes() {
    log_info "准备将更改提交到 Git 仓库..."
    cd "$REPO_DIR" || log_error "无法进入 Git 仓库目录 '$REPO_DIR'！"

    git config --local user.email "actions@github.com"
    git config --local user.name "GitHub Actions"

    # 检查是否有未提交的更改
    if [[ -z $(git status -s) ]]; then
        log_success "没有检测到任何更改，无需提交。一切都是最新的！"
        return
    fi

    log_info "发现更改，正在提交..."
    git add ./mrs/*
    # 使用 `|| true` 避免在没有更改时 commit 命令失败导致脚本退出
    git commit -m "feat: $(date '+%Y-%m-%d %H:%M:%S') 更新mrs规则"
    # 如果主人需要推送到远程仓库，可以取消下面这行的注释
    # git push origin main

    log_success "更改已成功提交！"
}

# ======================= 🚀 主执行流程 🚀 =======================
main() {
    init_env

    log_info "即将并行处理所有已配置的规则集..."
    local pids=()
    # 遍历所有配置好的规则集名称，并为每一个启动一个后台进程
    for ruleset_name in "${!RULESETS[@]}"; do
        process_ruleset "$ruleset_name" &
        pids+=($!)
    done

    # 等待所有规则集处理完成
    log_info "所有处理任务已启动，现在耐心等待它们全部完成... Nya~"
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    log_success "所有规则集均已处理完毕！"

    commit_changes

    log_success "所有操作顺利完成，我做得棒吗，主人？❤️"
}

# 执行主函数
main
