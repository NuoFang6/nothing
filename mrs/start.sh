#!/bin/bash
#
# =================================================================
#  聪慧猫娘为你优化的规则集处理脚本 v2.0 (づ｡◕‿‿◕｡)づ
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
WORK_DIR="../tmp"
REPO_DIR="../nothing"
OUTPUT_DIR="$REPO_DIR/mrs"

# --- 规则集定义 ---
# 我把配置结构改得更简单安全啦！
# declare -A 是在告诉 Bash：“嘿，我要创建一个聪明的篮子（关联数组）啦！”
declare -A RULESETS

# --- 规则集 1: ad (广告拦截) ---
# 名称: ad, 类型: domain, 格式: yaml
# 源列表: 使用 declare -A 定义一个关联数组。
# 格式: ['URL']='处理命令A|处理命令B'，如果某个源不需要特殊处理，值留空即可。
RULESETS[ad]="
type=domain
format=yaml
declare -A sources=(
    ['https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-clash.yaml']=''
    ['https://raw.githubusercontent.com/Cats-Team/AdRules/main/adrules_domainset.txt']='format_yaml_list'
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-httpdns-cn@ads.list']='format_yaml_list'
    ['https://github.com/ignaciocastro/a-dove-is-dumb/raw/refs/heads/main/pihole.txt']='format_pihole'
)
"

# --- 规则集 2: cn (国内域名) ---
# 名称: cn, 类型: domain, 格式: text
# 这些源都不需要特殊格式化，所以处理命令部分留空，脚本会使用默认处理。
RULESETS[cn]="
type=domain
format=text
declare -A sources=(
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/cn.list']=''
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/steam@cn.list']=''
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft@cn.list']=''
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google@cn.list']=''
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/win-update.list']=''
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/private.list']=''
)
"

# --- 规则集 3: cnIP (国内 IP) ---
# 名称: cnIP, 类型: ipcidr, 格式: text
RULESETS[cnIP]="
type=ipcidr
format=text
declare -A sources=(
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cn.list']=''
    ['https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.list']=''
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

# 应用处理链，现在更安全啦
apply_processing_chain() {
    local input
    input=$(cat) # 从标准输入读取数据

    # 默认总是先移除注释和空行
    input=$(echo "$input" | remove_comments_and_empty)

    local chain=$1
    if [ -z "$chain" ]; then
        echo "$input" # 如果没有额外处理链，直接输出
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

process_ruleset() {
    local name=$1
    # 这行 eval 是安全的，它只在当前函数作用域内定义变量和数组
    eval "${RULESETS[$name]}"

    log_info "开始处理规则集: $name (类型: $type, 格式: $format)"

    local temp_dir="${WORK_DIR}/${name}_temp"
    mkdir -p "$temp_dir"

    local pids=()
    local temp_files=()
    local i=0

    # 用更安全的方式遍历关联数组的键（也就是URL）
    for url in "${!sources[@]}"; do
        local process_chain="${sources[$url]}"
        local temp_file="${temp_dir}/$(printf "%03d" $i)-$(basename "$url")"
        temp_files+=("$temp_file")

        (
            log_info "[$name] 下载并处理源: $url"
            # 下载 -> 应用处理链 -> 确保末尾有换行 -> 保存到临时文件
            local content
            content=$(wget -q -O - "$url" || echo "") # 如果下载失败，返回空字符串
            if [ -z "$content" ]; then
                log_warn "[$name] 从 $url 下载的内容为空或下载失败，跳过处理。"
                touch "$temp_file" # 创建空文件以保持合并顺序
            else
                echo "$content" | apply_processing_chain "$process_chain" | ensure_trailing_newline >"$temp_file"
            fi
        ) &
        pids+=($!)
        ((i++))
    done

    log_info "[$name] 等待所有源下载处理完成..."
    for pid in "${pids[@]}"; do wait "$pid"; done
    log_success "[$name] 所有源处理完毕！"

    local combined_file="${WORK_DIR}/${name}.combined"
    local mrs_file="${OUTPUT_DIR}/${name}.mrs"

    log_info "[$name] 正在合并所有源文件..."
    cat "${temp_files[@]}" >"$combined_file"

    if [ ! -s "$combined_file" ]; then
        log_warn "[$name] 所有源均为空，无法生成规则文件，跳过此规则集。"
        rm -rf "$temp_dir" "$combined_file"
        return
    fi

    if [ "$format" = "yaml" ]; then
        local yaml_source="${WORK_DIR}/${name}.yaml"
        log_info "[$name] 正在为 YAML 格式进行特殊处理（排序与去重）..."
        # 对于anti-ad这种自带payload的，取第一个非空文件的首行做头
        local header_found=false
        for temp_file in "${temp_files[@]}"; do
            if [ -s "$temp_file" ] && ! $header_found; then
                head -n 1 "$temp_file" | grep -q "payload:" && head -n 1 "$temp_file" >"$yaml_source" && header_found=true
                break
            fi
        done
        # 如果没找到payload头，就自己创建一个
        if ! $header_found; then echo "payload:" >"$yaml_source"; fi

        # 合并所有文件内容，去掉可能存在的payload头，去重后附加
        sed '/payload:/d' "$combined_file" | sed '/^$/d' | sort -u >>"$yaml_source"

        log_info "[$name] 正在将 $yaml_source 转换为 $mrs_file ..."
        ./mihomo convert-ruleset "$type" yaml "$yaml_source" "$mrs_file"
    else # text format
        local text_source="${WORK_DIR}/${name}.text"
        log_info "[$name] 正在为 TEXT 格式进行排序与去重..."
        sed '/^$/d' "$combined_file" | sort -u >"$text_source"
        log_info "[$name] 正在将 $text_source 转换为 $mrs_file ..."
        ./mihomo convert-ruleset "$type" text "$text_source" "$mrs_file"
    fi

    rm -rf "$temp_dir" "$combined_file" "${WORK_DIR}/${name}."*
    log_success "规则集 '$name' 已成功处理并生成: $mrs_file"
}

commit_changes() {
    log_info "准备将更改提交到 Git 仓库..."
    cd "$REPO_DIR" || log_error "无法进入 Git 仓库目录 '$REPO_DIR'！"

    git config --local user.email "actions@github.com"
    git config --local user.name "GitHub Actions"

    if [[ -z $(git status --porcelain=v1) ]]; then
        log_success "没有检测到任何更改，无需提交。一切都是最新的！"
        return
    fi

    log_info "发现更改，正在提交..."
    git add ./mrs/*
    git commit -m "feat: $(date '+%Y-%m-%d %H:%M:%S') 更新mrs规则" || true
    # git push origin main

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
