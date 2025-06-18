#!/bin/bash
#
# =================================================================
#  聪慧猫娘为你优化的规则集处理脚本 v1.5 (最终诊断修复与日志究极体) (づ｡◕‿‿◕｡)づ
# =================================================================
#
#  功能:
#  1. 自动下载最新的 Mihomo (Clash.Meta) 核心。
#  2. 并行下载、处理多个规则源，并提供超详细的诊断日志。
#  3. 将处理后的规则转换为 .mrs 格式。
#  4. 自动提交更新到 Git 仓库。
#
#  更新日志 (v1.5):
#  - [根源修复] 彻底重写了配置解析逻辑，修复了当 `[process]` 不存在时 `url` 解析错误的致命 Bug。
#  - [功能] 将下载工具从 `wget` 更换为 `curl`，以获取更丰富的诊断信息（如 HTTP 状态码）。
#  - [日志] 究极进化！现在会详细记录每个源的 HTTP 返回码、下载前后文件大小和行数。
#  - [重构] 将下载和处理逻辑封装到独立的函数中，使代码更清晰、更健壮。
#
# =================================================================

# 脚本在任何命令失败时立即退出，并视管道中的任何失败为整个管道的失败
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

# --- 核心流程函数 ---

init_env() {
    log_info "开始初始化环境..."
    for tool in curl jq git sed; do
        if ! command -v "$tool" &>/dev/null; then log_error "必需的工具 '$tool' 未安装!"; fi
    done
    mkdir -p "$WORK_DIR" "$OUTPUT_DIR"
    cd "$WORK_DIR" || log_error "无法进入工作目录 '$WORK_DIR'！"
    log_info "正在寻找最新版的 Mihomo 核心..."
    local download_url
    download_url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases | jq -r '.[] | select(.tag_name | test("Prerelease-Alpha")) | .assets[] | select(.name | test("mihomo-linux-amd64-alpha-.*.gz")) | .browser_download_url' | head -1)
    if [ -z "$download_url" ]; then log_error "无法获取 Mihomo 下载链接。"; fi
    log_info "正在下载 Mihomo: $download_url"
    curl -sL "$download_url" | gunzip >mihomo
    chmod +x mihomo
    log_success "Mihomo 已准备就绪！"
}

# 新的下载和处理函数，包含了详细的日志和错误检查
download_and_process_source() {
    local name=$1
    local url=$2
    local process_chain=$3
    local temp_file=$4
    local http_code body_file

    body_file=$(mktemp) # 创建一个临时文件来存放下载内容

    log_info "[$name] -> 任务启动: 开始下载 $url"
    http_code=$(curl -L -s -w "%{http_code}" -o "$body_file" "$url")

    if [ "$http_code" -ne 200 ]; then
        log_warn "[$name] -> 下载失败! URL: $url, HTTP Status: $http_code"
        rm "$body_file"
        return 1 # 返回失败状态
    fi

    local size
    size=$(wc -c <"$body_file")
    log_info "[$name] -> 下载成功 (HTTP $http_code), 大小: $size 字节。"

    local processed_content
    processed_content=$(apply_processing_chain "$process_chain" <"$body_file" | ensure_trailing_newline)
    echo "$processed_content" >"$temp_file"

    local processed_size processed_lines
    processed_size=$(echo -n "$processed_content" | wc -c)
    processed_lines=$(echo -n "$processed_content" | wc -l)
    log_success "[$name] -> 任务完成: 源 $url 已处理并保存 (大小: $processed_size 字节, 行数: $processed_lines)。"

    rm "$body_file" # 清理临时下载文件
}

# 主处理函数，现在更健壮了
process_ruleset() {
    local name=$1
    local config_string="${RULESETS[$name]}"
    local type format
    type=$(echo "$config_string" | sed -n 's/^\s*type=\(.*\)\s*$/\1/p')
    format=$(echo "$config_string" | sed -n 's/^\s*format=\(.*\)\s*$/\1/p')
    if [ -z "$type" ] || [ -z "$format" ]; then log_error "[$name] 规则集配置不完整!"; fi

    log_info "[$name] 开始处理规则集 (类型: $type, 格式: $format)"
    local source_lines
    source_lines=$(echo "$config_string" | sed -n '/sources=(/,/)/p' | sed '1d;$d')
    local temp_dir="${WORK_DIR}/${name}_temp"
    mkdir -p "$temp_dir"

    local pids=()
    local temp_files=()
    local i=0

    # ==================== ✨ 这就是根源性修复！ ✨ ====================
    # 重写了解析逻辑，确保 url 和 process 都能被精确提取。
    while IFS= read -r source_config; do
        [[ -z "$source_config" ]] && continue

        local url process_chain
        # 这个 sed 命令会精确匹配 '...' 中的内容，无论后面有没有 [process]
        url=$(echo "$source_config" | sed -n "s/.*\[url\]='\([^']*\)'.*/\1/p")
        # 如果找到了 [process]，就提取；找不到就是空
        process_chain=$(echo "$source_config" | sed -n "s/.*\[process\]='\([^']*\)'.*/\1/p")

        # 如果 url 为空，说明解析失败，跳过这一行
        if [ -z "$url" ]; then
            log_warn "[$name] 无法解析配置行: $source_config"
            continue
        fi

        [ -z "$process_chain" ] && process_chain="remove_comments_and_empty"

        local temp_file="${temp_dir}/$(printf "%03d" $i)-$(basename "$url")"
        temp_files+=("$temp_file")

        # 将下载和处理逻辑放入后台执行
        download_and_process_source "$name" "$url" "$process_chain" "$temp_file" &
        pids+=($!)
        ((i++))
    done < <(echo "$source_lines")

    log_info "[$name] 所有下载任务已派出 (共 ${#pids[@]} 个)，等待它们完成..."
    local has_error=0
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            log_warn "[$name] 一个后台任务 (PID: $pid) 失败了喵..."
            has_error=1
        fi
    done
    if [ "$has_error" -ne 0 ]; then log_error "[$name] 部分下载任务失败，处理中止！"; fi
    log_success "[$name] 所有下载任务均已成功！"

    local combined_file="${WORK_DIR}/${name}.combined"
    log_info "[$name] 正在合并所有临时文件..."
    cat "${temp_files[@]}" >"$combined_file"
    log_info "[$name] -> 合并后总大小: $(wc -c <"$combined_file") 字节, 总行数: $(wc -l <"$combined_file")。"

    local final_file mrs_file="${OUTPUT_DIR}/${name}.mrs"
    if [ "$format" = "yaml" ]; then
        final_file="${WORK_DIR}/${name}.yaml"
        log_info "[$name] 正在为 YAML 格式排序与去重..."
        head -n1 "$combined_file" >"$final_file"
        tail -n +2 "$combined_file" | sed '/^$/d' | sort -u >>"$final_file"
    else # text format
        final_file="${WORK_DIR}/${name}.text"
        log_info "[$name] 正在为 TEXT 格式排序与去重..."
        sed '/^$/d' "$combined_file" | sort -u >"$final_file"
    fi
    log_info "[$name] -> 处理后大小: $(wc -c <"$final_file") 字节, 行数: $(wc -l <"$final_file")。"

    log_info "[$name] 正在使用 Mihomo 将其转换为 $mrs_file ..."
    ./mihomo convert-ruleset "$type" "$format" "$final_file" "$mrs_file"

    rm -rf "$temp_dir" "$combined_file" "$final_file"
    log_success "[$name] 规则集已成功生成: $mrs_file"
}

commit_changes() {
    log_info "准备将更改提交到 Git 仓库..."
    cd "$REPO_DIR" || log_error "无法进入 Git 仓库目录 '$REPO_DIR'！"
    git config --local user.email "actions@github.com"
    git config --local user.name "GitHub Actions"
    log_info "正在从远程仓库同步最新更改 (git pull --rebase)..."
    git pull --rebase origin main
    if [[ -z $(git status -s) ]]; then
        log_success "Git 仓库没有检测到任何更改，无需提交。"
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
    local main_pids=()
    for ruleset_name in "${!RULESETS[@]}"; do
        process_ruleset "$ruleset_name" &
        main_pids+=($!)
    done

    log_info "所有规则集处理进程已启动，耐心等待它们全部完成... Nya~"
    local main_has_error=0
    for pid in "${main_pids[@]}"; do
        if ! wait "$pid"; then
            log_warn "主循环检测到一个规则集处理进程 (PID: $pid) 失败。"
            main_has_error=1
        fi
    done

    if [ "$main_has_error" -ne 0 ]; then
        log_error "由于一个或多个规则集处理失败，脚本已中止。"
    fi

    log_success "所有规则集均已成功处理完毕！"
    commit_changes
    log_success "所有操作顺利完成，我做得棒吗，主人？"
}

main
