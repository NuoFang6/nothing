#!/bin/bash

# ================ 配置部分 ================
# 工作目录设置
WORK_DIR="../tmp"
REPO_DIR="../nothing"
OUTPUT_DIR="$REPO_DIR/mrs"

# ================ sed处理函数 ================
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

# 移除重复行
remove_duplicates() {
    awk '!seen[$0]++'
}

# 过滤被 +. 前缀规则覆盖的域名
filter_covered_domains() {
    # 创建临时文件
    local input_file=$1
    local output_file=$2
    local temp_file=$(mktemp)
    local prefix_temp=$(mktemp)
    local normal_temp=$(mktemp)

    # 处理YAML格式的头部，确保保留payload:行
    if grep -q "payload:" "$input_file"; then
        echo "payload:" >"$output_file"
    fi

    # 第一步：提取所有域名（去除格式前缀和后缀），分离+.域名和普通域名
    awk '
    !/^payload:/ {  # 跳过payload行
        if ($0 ~ /\+\./) {
            # 带+.前缀的域名
            domain = $0
            gsub(/^.*[\047"]\+\./, "", domain)  # 移除前缀和+.
            gsub(/[\047"].*$/, "", domain)      # 移除后缀
            print domain > "'$prefix_temp'"
        } else if ($0 ~ /[\047"]/) {
            # 普通域名
            domain = $0
            gsub(/^.*[\047"]/, "", domain)      # 移除前缀
            gsub(/[\047"].*$/, "", domain)      # 移除后缀
            print domain > "'$normal_temp'"
        }
    }' "$input_file"

    # 将+.域名加载到关联数组
    declare -A prefix_domains
    while read -r domain; do
        prefix_domains["$domain"]=1
    done <"$prefix_temp"

    # 过滤普通域名，排除已有+.版本的
    while read -r domain; do
        if [[ -z "${prefix_domains[$domain]}" ]]; then
            # 保存没有+.版本的普通域名
            echo "$domain" >>"$temp_file"
        fi
    done <"$normal_temp"

    # 添加所有+.域名
    cat "$prefix_temp" >>"$temp_file"

    # 排序并格式化输出
    if grep -q "  - " "$input_file" | head -1; then
        # YAML格式
        sort "$temp_file" | awk '{
            if ($0 ~ /^[^+]/) {
                # 普通域名
                print "  - '\''" $0 "'\''";
            } else {
                # +.域名 (已经处理过，不含+.前缀了)
                print "  - '\''+." $0 "'\''";
            }
        }' >>"$output_file"
    else
        # 文本格式
        sort "$temp_file" | awk '{
            if ($0 ~ /^[^+]/) {
                # 普通域名
                print $0
            } else {
                # +.域名 (已经处理过，不含+.前缀了)
                print "+." $0
            }
        }' >"$output_file"
    fi

    # 清理临时文件
    rm -f "$temp_file" "$prefix_temp" "$normal_temp"
}

# 按字典序排序规则（忽略YAML语法）
sort_rules() {
    local input_file=$1
    local temp_file=$(mktemp)
    local header_file=$(mktemp)
    local content_file=$(mktemp)

    # 如果是YAML格式，保留payload:行
    if grep -q "^payload:" "$input_file"; then
        grep "^payload:" "$input_file" >"$header_file"
        grep -v "^payload:" "$input_file" >"$content_file"
    else
        # 如果是文本格式，不需要处理header
        touch "$header_file" # 创建空文件
        cat "$input_file" >"$content_file"
    fi

    # 提取域名部分并排序
    awk '{
        # 保存原始行
        orig_line = $0
        
        # 提取域名部分 (去除前缀和引号)
        if ($0 ~ /\+\./) {
            # 对于 +. 开头的域名
            domain = $0
            gsub(/^.*[\047"]\+\./, "", domain)  # 移除前缀和+.
            gsub(/[\047"].*$/, "", domain)      # 移除后缀
            # 输出: 域名 + 原始行 (用特殊分隔符分开)
            print domain "§§§" orig_line
        } else {
            # 对于普通域名
            domain = $0
            gsub(/^.*[\047"]/, "", domain)      # 移除前缀
            gsub(/[\047"].*$/, "", domain)      # 移除后缀
            # 输出: 域名 + 原始行 (用特殊分隔符分开)
            print domain "§§§" orig_line
        }
    }' "$content_file" | sort | awk -F "§§§" '{print $2}' >"$temp_file"

    # 合并header和排序后的内容
    cat "$header_file" "$temp_file" >"$input_file"

    # 清理临时文件
    rm -f "$temp_file" "$header_file" "$content_file"
}

# 数据源配置
# ad 规则源
AD_SOURCES=(
    "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-clash.yaml|yaml|remove_comments_and_empty"
    "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-httpdns-cn@ads.list|text|remove_comments_and_empty|format_yaml_list"
    "https://github.com/ignaciocastro/a-dove-is-dumb/raw/refs/heads/main/pihole.txt|text|remove_comments_and_empty|format_pihole"
)

# cn 规则源
CN_SOURCES=(
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/cn.list"
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/steam@cn.list"
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft@cn.list"
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google@cn.list"
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/win-update.list"
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/private.list"
)

# cnIP 规则源
CNIP_SOURCES=(
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cn.list"
    "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.list"
)

# ================ 工具函数 ================
# 初始化环境
init_env() {
    echo "正在初始化环境..."
    # 修改时区
    sudo timedatectl set-timezone 'Asia/Shanghai'

    # 创建工作目录
    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || exit 1

    # 下载最新 mihomo
    echo "下载Mihomo工具..."
    local download_url
    download_url=$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases |
        jq -r '.[] | select(.tag_name | test("Prerelease-Alpha")) | 
                 .assets[] | select(.name | test("mihomo-linux-amd64-alpha-.*.gz")) | 
                 .browser_download_url' | head -1)

    if [ -z "$download_url" ]; then
        echo "错误：无法获取Mihomo下载链接"
        exit 1
    fi

    wget -q -O mihomo.gz "$download_url"
    gunzip mihomo.gz
    chmod +x mihomo

    echo "环境初始化完成"
}

# 并行处理规则并转换为MRS格式
process_ruleset_parallel() {
    local name=$1
    local type=$2
    local format=$3
    local sources=("${!4}")

    echo "处理 $name 规则集..."

    # 创建临时目录
    local temp_dir="${WORK_DIR}/${name}_temp"
    mkdir -p "$temp_dir"

    # 并行下载和处理每个源
    local i=0
    local pids=()
    local temp_files=()

    for source in "${sources[@]}"; do
        IFS="|" read -r url format_override process_cmd <<<"$source"
        local old_ifs="$IFS"

        # 创建带序号的临时文件名，确保后续能按顺序合并
        local temp_file="${temp_dir}/${i}_$(basename "$url")"
        temp_files+=("$temp_file")

        # 启动后台进程下载和处理
        (
            echo "从 $url 下载..."

            # 如果提供了特定格式和处理命令，则使用它们
            if [ -n "$format_override" ] && [ -n "$process_cmd" ]; then
                echo "应用自定义处理..."
                wget -q -O - "$url" | eval "$process_cmd" | ensure_trailing_newline >"$temp_file"
            else
                wget -q -O - "$url" | remove_comments_and_empty | ensure_trailing_newline >"$temp_file"
            fi

            if [ $? -ne 0 ]; then
                echo "警告：下载或处理 $url 时出错"
            fi
        ) &

        # 保存后台进程的PID
        pids+=($!)

        let i++
        IFS="$old_ifs" # 恢复原始IFS值
    done

    # 等待所有下载完成
    echo "等待 $name 的所有下载完成..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # 按顺序合并文件
    echo "合并 $name 的所有源..."
    >"${WORK_DIR}/${name}"
    for temp_file in "${temp_files[@]}"; do
        cat "$temp_file" >>"${WORK_DIR}/${name}"
    done # 去重并准备转换
    if [ "$format" = "yaml" ]; then
        # 先去重
        cat "${WORK_DIR}/${name}" | remove_duplicates | sed "/^$/d" >"${WORK_DIR}/${name}.yaml"

        # 过滤被 +. 前缀覆盖的域名（类型为 domain 时才处理）
        if [ "$type" = "domain" ]; then
            echo "过滤被 +. 前缀规则覆盖的域名..."
            filter_covered_domains "${WORK_DIR}/${name}.yaml" "${WORK_DIR}/${name}.filtered.yaml"
            mv "${WORK_DIR}/${name}.filtered.yaml" "${WORK_DIR}/${name}.yaml"
        fi

        # 按字典序排序规则
        echo "按字典序排序规则..."
        sort_rules "${WORK_DIR}/${name}.yaml"

        # 转换为 MRS 格式
        ./mihomo convert-ruleset "$type" yaml "${WORK_DIR}/${name}.yaml" "${WORK_DIR}/${name}.mrs"
        mv -f "${WORK_DIR}/${name}.yaml" "${WORK_DIR}/${name}.mrs" "$OUTPUT_DIR/"
    else
        # 先去重
        cat "${WORK_DIR}/${name}" | remove_duplicates | sed "/^$/d" >"${WORK_DIR}/${name}.text"

        # 过滤被 +. 前缀覆盖的域名（类型为 domain 时才处理）
        if [ "$type" = "domain" ]; then
            echo "过滤被 +. 前缀规则覆盖的域名..."
            filter_covered_domains "${WORK_DIR}/${name}.text" "${WORK_DIR}/${name}.filtered.text"
            mv "${WORK_DIR}/${name}.filtered.text" "${WORK_DIR}/${name}.text"
        fi

        # 按字典序排序规则
        echo "按字典序排序规则..."
        sort_rules "${WORK_DIR}/${name}.text"

        # 转换为 MRS 格式
        ./mihomo convert-ruleset "$type" text "${WORK_DIR}/${name}.text" "${WORK_DIR}/${name}.mrs"
        mv -f "${WORK_DIR}/${name}.text" "${WORK_DIR}/${name}.mrs" "$OUTPUT_DIR/"
    fi

    # 清理临时目录
    rm -rf "$temp_dir"

    echo "$name 规则集处理完成"
}

# 提交更改到Git仓库
commit_changes() {
    echo "提交更改到Git仓库..."
    cd "$REPO_DIR" || exit 1
    git config --local user.email "actions@github.com"
    git config --local user.name "GitHub Actions"
    git pull origin main
    git add ./mrs/*
    git commit -m "$(date '+%Y-%m-%d %H:%M:%S') 更新mrs规则" || echo "没有需要提交的更改"
    echo "提交完成"
}

# ================ 主执行流程 ================
main() {
    # 初始化环境
    init_env

    # 并行处理各种规则集
    process_ruleset_parallel "ad" "domain" "yaml" AD_SOURCES[@] &
    pid1=$!
    process_ruleset_parallel "cn" "domain" "text" CN_SOURCES[@] &
    pid2=$!
    process_ruleset_parallel "cnIP" "ipcidr" "text" CNIP_SOURCES[@] &
    pid3=$!

    # 等待所有处理完成
    wait $pid1 $pid2 $pid3

    # 提交更改
    commit_changes

    echo "所有操作已完成"
}

# 执行主函数
main
