#!/bin/bash
#
# =================================================================
#  聪慧猫娘为你优化的规则集处理脚本 v1.9 (流式处理 · 磐石版) (づ｡◕‿‿◕｡)づ
# =================================================================
#
#  功能:
#  1. 自动下载最新的 Mihomo (Clash.Meta) 核心。
#  2. 串行处理规则集，并行下载每个规则集内的源文件，提供可追踪的诊断日志。
#  3. 将处理后的规则转换为 .mrs 格式。
#  4. 自动提交更新到 Git 仓库。
#
#  更新日志 (v1.9):
#  - [根源修复] 重构数据处理核心！将 `apply_processing_chain` 从变量存储改为流式处理，
#    彻底解决了因 `echo` 无法处理大文件而导致进程失败的根本性问题。
#  - [日志] 增加了更精细的日志节点，现在可以清晰地看到数据处理的每一步。
#
# =================================================================

set -e
set -o pipefail

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

# ======================= 🔧 工具与辅助函数定义 🔧 =======================

# --- 日志函数 ---
COLOR_RESET='\033[0m'; COLOR_INFO='\033[0;34m'; COLOR_SUCCESS='\033[0;32m'; COLOR_WARNING='\033[0;33m'; COLOR_ERROR='\033[0;31m'
log_info() { echo -e "${COLOR_INFO}INFO: $1 $2${COLOR_RESET}"; }
log_success() { echo -e "${COLOR_SUCCESS}SUCCESS: $1 $2${COLOR_RESET}"; }
log_warn() { echo -e "${COLOR_WARNING}WARNING: $1 $2${COLOR_RESET}"; }
log_error() { echo -e "${COLOR_ERROR}ERROR: $1 $2${COLOR_RESET}"; exit 1; }

# --- 文本处理小工具 ---
remove_comments_and_empty() { sed '/^#/d; /^$/d;'; }
ensure_trailing_newline() { sed -e '$a\'; }
add_prefix_suffix() { sed "s/^/${1}/; s/$/${2}/"; }
format_pihole() { add_prefix_suffix "  - '+." "'"; }
format_yaml_list() { add_prefix_suffix "  - '" "'"; }

# ==================== ✨ 这就是核心修复！ ✨ ====================
# `apply_processing_chain` 现在是一个真正的“流式”过滤器。
# 它从标准输入读取数据，并将处理后的数据输出到标准输出，全程不使用变量存储。
apply_processing_chain() {
    local chain=$1
    if [ -z "$chain" ]; then
        cat # 如果没有处理链，就直接将输入原样输出
        return
    fi
    IFS='|' read -ra funcs <<< "$chain"
    local pipeline_cmd="${funcs[0]}"
    for (( i=1; i<${#funcs[@]}; i++ )); do
        pipeline_cmd+=" | ${funcs[$i]}"
    done
    eval "$pipeline_cmd" # 使用 eval 执行构建好的完整管道命令
}
# =============================================================

# --- 核心流程函数 ---

init_env() {
    local tag="[INIT]"
    log_info "$tag" "开始初始化环境..."
    for tool in curl jq git sed; do if ! command -v "$tool" &> /dev/null; then log_error "$tag" "必需的工具 '$tool' 未安装!"; fi; done
    mkdir -p "$WORK_DIR" "$OUTPUT_DIR"; cd "$WORK_DIR" || log_error "$tag" "无法进入工作目录 '$WORK_DIR'！"
    log_info "$tag" "正在寻找最新版的 Mihomo 核心..."; local download_url
    download_url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases | jq -r '.[] | select(.tag_name | test("Prerelease-Alpha")) | .assets[] | select(.name | test("mihomo-linux-amd64-alpha-.*.gz")) | .browser_download_url' | head -1)
    if [ -z "$download_url" ]; then log_error "$tag" "无法获取 Mihomo 下载链接。"; fi
    log_info "$tag" "正在下载 Mihomo: $download_url"; curl -sL "$download_url" | gunzip > mihomo; chmod +x mihomo
    log_success "$tag" "Mihomo 已准备就绪！"
}

download_and_process_source() {
    local name=$1 url=$2 process_chain=$3 temp_file=$4
    local tag="[$name][Worker]"
    local http_code body_file; body_file=$(mktemp)
    
    log_info "$tag" "任务启动 (PID:$$): 开始下载 $url"
    http_code=$(curl -L -s -w "%{http_code}" -o "$body_file" "$url")

    if [ "$http_code" -ne 200 ]; then
        log_warn "$tag" "(PID:$$) 下载失败! URL: $url, HTTP Status: $http_code"; rm "$body_file"; exit 11
    fi
    log_info "$tag" "(PID:$$) 下载成功 (HTTP $http_code), 大小: $(wc -c < "$body_file") 字节。"

    # 现在是真正的流式处理，数据从文件流出，经过处理链，直接流入最终的临时文件
    log_info "$tag" "(PID:$$) 开始流式处理数据..."
    apply_processing_chain "$process_chain" < "$body_file" | ensure_trailing_newline > "$temp_file"
    
    log_success "$tag" "(PID:$$) 任务完成: 源 $url 已处理并保存。"
    rm "$body_file"
}

process_ruleset() {
    local name=$1; local tag="[$name]"; local config_string="${RULESETS[$name]}"; local type format
    type=$(echo "$config_string" | sed -n 's/^\s*type=\(.*\)\s*$/\1/p')
    format=$(echo "$config_string" | sed -n 's/^\s*format=\(.*\)\s*$/\1/p')
    if [ -z "$type" ] || [ -z "$format" ]; then log_error "$tag" "规则集配置不完整!"; fi

    log_info "$tag" "===> 开始处理规则集 (类型: $type, 格式: $format) <==="
    local source_lines; source_lines=$(echo "$config_string" | sed -n '/sources=(/,/)/p' | sed '1d;$d')
    local temp_dir="${WORK_DIR}/${name}_temp"; mkdir -p "$temp_dir"

    local pids=(); local temp_files=(); local i=0
    while IFS= read -r source_config; do
        [[ -z "$source_config" ]] && continue
        local url process_chain
        url=$(echo "$source_config" | sed -n "s/.*\[url\]='\([^']*\)'.*/\1/p")
        process_chain=$(echo "$source_config" | sed -n "s/.*\[process\]='\([^']*\)'.*/\1/p")
        if [ -z "$url" ]; then log_warn "$tag" "无法解析配置行: $source_config"; continue; fi
        [ -z "$process_chain" ] && process_chain="remove_comments_and_empty"
        local temp_file="${temp_dir}/$(printf "%03d" $i)-$(basename "$url")"; temp_files+=("$temp_file")
        download_and_process_source "$name" "$url" "$process_chain" "$temp_file" &
        pids+=($!)
        ((i++))
    done < <(echo "$source_lines")

    log_info "$tag" "所有下载任务已派出 (共 ${#pids[@]} 个)，等待它们完成..."
    local has_error=0
    for pid in "${pids[@]}"; do
        local exit_code=0; wait "$pid" || exit_code=$?;
        if [ "$exit_code" -ne 0 ]; then
            log_warn "$tag" "检测到一个后台任务 (PID: $pid) 失败，真实退出码: $exit_code"; has_error=1
        fi
    done
    if [ "$has_error" -ne 0 ]; then log_error "$tag" "部分下载任务失败，处理中止！"; fi
    log_success "$tag" "所有下载任务均已成功！"

    local combined_file="${WORK_DIR}/${name}.combined"; log_info "$tag" "正在合并所有临时文件..."
    cat "${temp_files[@]}" > "$combined_file"
    log_info "$tag" "-> 合并后总大小: $(wc -c < "$combined_file") 字节, 总行数: $(wc -l < "$combined_file")。"

    local final_file mrs_file="${OUTPUT_DIR}/${name}.mrs";
    if [ "$format" = "yaml" ]; then
        final_file="${WORK_DIR}/${name}.yaml"; log_info "$tag" "正在为 YAML 格式排序与去重..."
        head -n1 "$combined_file" > "$final_file"; tail -n +2 "$combined_file" | sed '/^$/d' | sort -u >> "$final_file"
    else
        final_file="${WORK_DIR}/${name}.text"; log_info "$tag" "正在为 TEXT 格式排序与去重..."
        sed '/^$/d' "$combined_file" | sort -u > "$final_file"
    fi
    log_info "$tag" "-> 处理后大小: $(wc -c < "$final_file") 字节, 行数: $(wc -l < "$final_file")。"
    log_info "$tag" "正在使用 Mihomo 将其转换为 $mrs_file ..."; ./mihomo convert-ruleset "$type" "$format" "$final_file" "$mrs_file"
    rm -rf "$temp_dir" "$combined_file" "$final_file"
    log_success "$tag" "===> 规则集已成功处理完毕 <==="; echo
}

commit_changes() {
    local tag="[GIT]"; log_info "$tag" "准备将更改提交到 Git 仓库..."; cd "$REPO_DIR" || log_error "$tag" "无法进入 Git 仓库目录 '$REPO_DIR'！"
    git config --local user.email "actions@github.com"; git config --local user.name "GitHub Actions"
    log_info "$tag" "正在从远程仓库同步最新更改 (git pull --rebase)..."; git pull --rebase origin main
    if [[ -z $(git status -s) ]]; then log_success "$tag" "Git 仓库没有检测到任何更改，无需提交。"; return; fi
    log_info "$tag" "发现更改，正在提交..."; git add ./mrs/*; git commit -m "feat: $(date '+%Y-%m-%d %H:%M:%S') 更新mrs规则"
    log_success "$tag" "更改已成功提交！"
}

# ======================= ✨ 函数导出区域 ✨ =======================
# 只导出需要在后台（子进程）中使用的函数
export -f log_info log_success log_warn log_error
export -f remove_comments_and_empty ensure_trailing_newline add_prefix_suffix
export -f format_pihole format_yaml_list apply_processing_chain
export -f download_and_process_source
# =============================================================

# ======================= 🚀 主执行流程 🚀 =======================
main() {
    init_env
    log_info "[MainLoop]" "即将开始处理所有规则集..."
    for ruleset_name in "${!RULESETS[@]}"; do
        process_ruleset "$ruleset_name"
    done
    log_success "[MainLoop]" "所有规则集均已成功处理完毕！"
    commit_changes
    log_success "[MainLoop]" "所有操作顺利完成。这次我做对了吗，主人？ (´｡• ᵕ •｡`) ♡"
}

main