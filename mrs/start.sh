#!/bin/bash
#
# =================================================================
#  聪慧猫娘为你优化的规则集处理脚本 v1.2 (终极修复版) (づ｡◕‿‿◕｡)づ
# =================================================================
#
#  功能:
#  1. 自动下载最新的 Mihomo (Clash.Meta) 核心。
#  2. 并行下载、处理多个规则源。
#  3. 将处理后的规则转换为 .mrs 格式。
#  4. 自动提交更新到 Git 仓库。
#
#  更新日志 (v1.2):
#  - [修复] 彻底移除了所有 `eval` 命令，根除了因特殊字符导致的语法错误。
#  - [优化] 使用更健壮的文本解析方式读取规则集配置。
#  - [优化] 增强了并行任务的错误处理和日志反馈。
#
# =================================================================

set -e          # 任何命令失败则立即退出
set -o pipefail # 管道中的任何一个命令失败，整个管道都视为失败

# ======================= ✨ 核心配置区域 ✨ =======================
# 主人，所有的魔法都从这里开始哦！以后修改和添加规则只需要动这里~

# --- 基础路径设置 ---
WORK_DIR="../tmp"
REPO_DIR="../nothing"
OUTPUT_DIR="$REPO_DIR/mrs"

# --- 规则集定义 ---
declare -A RULESETS

# --- 规则集 1: ad (广告拦截) ---
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
RULESETS[cnIP]="
type=ipcidr
format=text
sources=(
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cn.list'
    [url]='https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.list'
)
"

# ======================= 🔧 工具与辅助函数 🔧 =======================

# --- 日志函数 ---
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
remove_comments_and_empty() { sed '/^#/d; /^$/d;'; }
ensure_trailing_newline() { sed -e '$a\'; }
add_prefix_suffix() { sed "s/^/${1}/; s/$/${2}/"; }
format_pihole() { add_prefix_suffix "  - '+." "'"; }
format_yaml_list() { add_prefix_suffix "  - '" "'"; }

apply_processing_chain() {
    local chain=$1
    local input
    input=$(cat)
    if [ -z "$chain" ]; then
        echo "$input"
        return
    fi
    IFS='|' read -ra funcs <<<"$chain"
    for func in "${funcs[@]}"; do
        input=$(echo "$input" | "$func")
    done
    echo "$input"
}

# --- 核心功能函数 ---

init_env() {
    log_info "开始初始化环境..."
    for tool in curl jq git wget; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "必需的工具 '$tool' 未安装，请先安装它再来找我哦~"
        fi
    done
    mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
    cd "$WORK_DIR" || log_error "无法进入工作目录 '$WORK_DIR'！"

    log_info "正在寻找最新版的 Mihomo 核心..."
    local download_url
    download_url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases |
        jq -r '.[] | select(.tag_name | test("Prerelease-Alpha")) |
                 .assets[] | select(.name | test("mihomo-linux-amd64-alpha-.*.gz")) |
                 .browser_download_url' | head -1)
    if [ -z "$download_url" ]; then
        log_error "无法获取 Mihomo 下载链接，可能是网络问题或 GitHub API 限制了。"
    fi
    log_info "正在下载 Mihomo: $download_url"
    wget -q -O mihomo.gz "$download_url"
    gunzip -f mihomo.gz
    chmod +x mihomo
    log_success "Mihomo 已准备就绪！"
}

# ==================== ✨ 这里是修复的核心！ ✨ ====================
#  我重写了这里，彻底抛弃了不稳定的 `eval`，手动解析配置，保证万无一失！
# =================================================================
process_ruleset() {
    local name=$1
    local config_string="${RULESETS[$name]}"

    # 使用 grep 和 cut 精确提取 type 和 format
    local type
    local format
    type=$(echo "$config_string" | grep -oP '^\s*type=\K.*' || echo "")
    format=$(echo "$config_string" | grep -oP '^\s*format=\K.*' || echo "")

    # 检查是否成功获取了配置
    if [ -z "$type" ] || [ -z "$format" ]; then
        log_error "规则集 '$name' 的配置不完整，缺少 type 或 format！"
    fi

    log_info "开始处理规则集: $name (类型: $type, 格式: $format)"

    # 使用 sed 提取 sources(...) 中的所有行
    local source_lines
    source_lines=$(echo "$config_string" | sed -n '/sources=(/,/)/p' | sed '1d;$d')

    local temp_dir="${WORK_DIR}/${name}_temp"
    mkdir -p "$temp_dir"

    local pids=()
    local temp_files=()
    local i=0

    # 使用 while read 循环处理每一行源配置
    while IFS= read -r source_config; do
        # 跳过空行
        [[ -z "$source_config" ]] && continue

        # 使用更健壮的方式提取 url 和 process
        local url
        local process_chain
        url=$(echo "$source_config" | grep -o "\[url\]='[^']*" | sed "s/\[url\]='//")
        process_chain=$(echo "$source_config" | grep -o "\[process\]='[^']*" | sed "s/\[process\]='//")

        # 如果没有定义 process, 默认只移除注释和空行
        [ -z "$process_chain" ] && process_chain="remove_comments_and_empty"

        local temp_file="${temp_dir}/$(printf "%03d" $i)-$(basename "$url")"
        temp_files+=("$temp_file")

        (
            log_info "[$name] 下载并处理源: $url"
            local content
            content=$(wget -q -O - "$url")
            if [ -z "$content" ]; then
                log_warn "[$name] 从 $url 下载的内容为空，跳过处理。"
                touch "$temp_file"
            else
                echo "$content" | apply_processing_chain "$process_chain" | ensure_trailing_newline >"$temp_file"
            fi
        ) &
        pids+=($!)
        ((i++))
    done <<<"$source_lines"

    log_info "[$name] 等待所有源下载处理完成..."
    local has_error=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            log_warn "[$name] 一个后台下载/处理任务 (PID: $pid) 失败了喵..."
            has_error=1
        fi
    done
    if [ "$has_error" -ne 0 ]; then
        log_error "[$name] 部分后台任务失败，处理中止！"
    fi
    log_success "[$name] 所有源处理完毕！"

    local combined_file="${WORK_DIR}/${name}.combined"
    local final_file_prefix="${WORK_DIR}/${name}"
    local mrs_file="${OUTPUT_DIR}/${name}.mrs"

    log_info "[$name] 正在合并所有源文件..."
    cat "${temp_files[@]}" >"$combined_file"

    if [ "$format" = "yaml" ]; then
        local yaml_source="${final_file_prefix}.yaml"
        log_info "[$name] 正在为 YAML 格式进行特殊处理（排序与去重）..."
        head -n1 "$combined_file" >"$yaml_source"
        tail -n +2 "$combined_file" | sed '/^$/d' | sort -u >>"$yaml_source"
        log_info "[$name] 正在将 $yaml_source 转换为 $mrs_file ..."
        ./mihomo convert-ruleset "$type" yaml "$yaml_source" "$mrs_file"
    else # text format
        local text_source="${final_file_prefix}.text"
        log_info "[$name] 正在为 TEXT 格式进行排序与去重..."
        sed '/^$/d' "$combined_file" | sort -u >"$text_source"
        log_info "[$name] 正在将 $text_source 转换为 $mrs_file ..."
        ./mihomo convert-ruleset "$type" text "$text_source" "$mrs_file"
    fi

    rm -rf "$temp_dir" "$combined_file" "${final_file_prefix}."*
    log_success "规则集 '$name' 已成功处理并生成: $mrs_file"
}

commit_changes() {
    log_info "准备将更改提交到 Git 仓库..."
    cd "$REPO_DIR" || log_error "无法进入 Git 仓库目录 '$REPO_DIR'！"

    git config --local user.email "actions@github.com"
    git config --local user.name "GitHub Actions"

    log_info "正在从远程仓库同步最新更改..."
    git pull --rebase origin main

    if [[ -z $(git status -s) ]]; then
        log_success "没有检测到任何更改，无需提交。一切都是最新的！"
        return
    fi

    log_info "发现更改，正在提交..."
    git add ./mrs/*
    git commit -m "feat: $(date '+%Y-%m-%d %H:%M:%S') 更新mrs规则"
    log_success "更改已成功提交！"
}

# ======================= 🚀 主执行流程 🚀 =======================
main() {
    init_env

    log_info "即将并行处理所有已配置的规则集..."
    local pids=()
    for ruleset_name in "${!RULESETS[@]}"; do
        process_ruleset "$ruleset_name" &
        pids+=($!)
    done

    log_info "所有处理任务已启动，现在耐心等待它们全部完成... Nya~"
    for pid in "${pids[@]}"; do wait "$pid"; done
    log_success "所有规则集均已处理完毕！"

    commit_changes

    log_success "所有操作顺利完成，我做得棒吗，主人？"
}

main
