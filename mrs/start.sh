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
        IFS="|" read -r url format_override process_cmd <<< "$source"
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
                wget -q -O - "$url" | eval "$process_cmd" | ensure_trailing_newline > "$temp_file"
            else
                wget -q -O - "$url" | remove_comments_and_empty | ensure_trailing_newline > "$temp_file"
            fi
            
            if [ $? -ne 0 ]; then
                echo "警告：下载或处理 $url 时出错"
            fi
        ) &
        
        # 保存后台进程的PID
        pids+=($!)
        
        let i++
        IFS="$old_ifs"  # 恢复原始IFS值
    done
    
    # 等待所有下载完成
    echo "等待 $name 的所有下载完成..."
    for pid in "${pids[@]}"; do
        wait "$pid"
    done
    
    # 按顺序合并文件
    echo "合并 $name 的所有源..."
    > "${WORK_DIR}/${name}"
    for temp_file in "${temp_files[@]}"; do
        cat "$temp_file" >> "${WORK_DIR}/${name}"
    done
    
    # 去重并准备转换
    if [ "$format" = "yaml" ]; then
        cat "${WORK_DIR}/${name}" | remove_duplicates | sed "/^$/d" > "${WORK_DIR}/${name}.yaml"
        ./mihomo convert-ruleset "$type" yaml "${WORK_DIR}/${name}.yaml" "${WORK_DIR}/${name}.mrs"
        mv -f "${WORK_DIR}/${name}.yaml" "${WORK_DIR}/${name}.mrs" "$OUTPUT_DIR/"
    else
        cat "${WORK_DIR}/${name}" | remove_duplicates | sed "/^$/d" > "${WORK_DIR}/${name}.text"
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

# 清理Git提交历史 (使用 git filter-repo)
clean_git_history() {
    echo "检查是否需要清理Git提交历史..."
    cd "$REPO_DIR" || exit 1

    # 检查 git-filter-repo 是否安装
    if ! command -v git-filter-repo >/dev/null 2>&1; then
        echo "git-filter-repo 未找到，尝试安装..."
        # 尝试使用 apt-get (适用于Debian/Ubuntu)
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get update && sudo apt-get install -y git-filter-repo
        # 尝试使用 pip3 (通用Python包管理器)
        elif command -v pip3 >/dev/null 2>&1; then
             echo "尝试使用 pip3 安装 git-filter-repo..."
             pip3 install git-filter-repo
        else
            echo "错误：无法找到 apt-get 或 pip3 来安装 git-filter-repo。请确保已安装 git-filter-repo。"
            # 根据需要决定是否退出脚本
            # exit 1
            echo "跳过历史清理步骤。"
            return
        fi
        # 再次检查安装是否成功
        if ! command -v git-filter-repo >/dev/null 2>&1; then
            echo "错误：git-filter-repo 安装失败。跳过历史清理步骤。"
            return
        fi
        echo "git-filter-repo 安装成功。"
    fi

    # 统计actions用户的提交数量
    local actions_commits_count
    # 确保在 main 分支上操作
    git checkout main
    git pull origin main # 获取最新更改
    actions_commits_count=$(git log --author="GitHub Actions" --pretty=format:"%H" | wc -l)

    echo "GitHub Actions用户的提交数量: $actions_commits_count"

    # 如果actions用户的提交数量大于7，则只保留最新的3次提交
    if [ "$actions_commits_count" -gt 7 ]; then
        echo "提交数量超过 7 次，开始使用 git-filter-repo 清理历史..."

        # 获取所有 GitHub Actions 提交的 SHA
        local all_ga_commits
        all_ga_commits=$(git log --author="GitHub Actions" --pretty=format:"%H")

        # 获取需要移除的提交 SHA (除了最新的3个之外的所有)
        local remove_ga_commits
        # 使用 tail -n +4 来获取第4个及之后的所有行
        remove_ga_commits=$(echo "$all_ga_commits" | tail -n +4)

        if [ -z "$remove_ga_commits" ]; then
            echo "没有找到需要移除的旧提交。跳过清理。"
            return
        fi

        # 创建临时文件存储要移除的 commit ID
        local temp_commit_file
        temp_commit_file=$(mktemp)
        # 检查 mktemp 是否成功
        if [ -z "$temp_commit_file" ] || [ ! -f "$temp_commit_file" ]; then
            echo "错误：无法创建临时文件。跳过清理。"
            return
        fi

        echo "$remove_ga_commits" > "$temp_commit_file"
        echo "准备移除以下提交："
        cat "$temp_commit_file"

        # 使用 git filter-repo 移除指定的提交
        # --force 用于覆盖 .git/filter-repo/ 目录（如果存在）
        # --refs main 指定只重写 main 分支的历史
        echo "正在执行 git filter-repo..."
        if git filter-repo --strip-commit-ids-file "$temp_commit_file" --refs main --force; then
            echo "Git历史清理成功，已移除旧的 GitHub Actions 提交。"

            # 清理临时文件
            rm "$temp_commit_file"

            # 强制推送更新后的 main 分支
            echo "强制推送更新后的 main 分支..."
            if git push origin main --force; then
                echo "强制推送成功。"
            else
                echo "错误：强制推送失败。可能需要手动干预。"
                # 可以选择返回错误码
                # return 1
            fi
        else
            echo "错误：git filter-repo 执行失败。"
            # 清理临时文件
            rm "$temp_commit_file"
            # 可以选择返回错误码
            # return 1
        fi
    else
        echo "GitHub Actions用户的提交数量未超过 7 次，无需清理"
    fi
    # 切换回之前的状态或保持在main分支
    # git checkout - # 如果需要切换回之前的分支
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

    # 清理提交历史
    clean_git_history

    echo "所有操作已完成"
}

# 执行主函数
main