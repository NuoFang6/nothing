#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import requests
import gzip
import shutil
import subprocess
import json
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from zoneinfo import ZoneInfo # Python 3.9+ standard library

# ================ 配置部分 ================
# 使用 pathlib 让路径操作更简单、更跨平台
BASE_DIR = Path(__file__).parent
WORK_DIR = BASE_DIR / "tmp"
REPO_DIR = BASE_DIR / "nothing"
OUTPUT_DIR = REPO_DIR / "mrs"

# --- 数据源配置 ---
# 使用字典列表，结构更清晰
AD_SOURCES = [
    {"url": "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-clash.yaml", "format_override": "yaml", "processors": ["remove_comments_and_empty"]},
    {"url": "https://github.com/Cats-Team/AdRules/main/adrules_domainset.txt", "format_override": "text", "processors": ["remove_comments_and_empty", "format_yaml_list"]},
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-httpdns-cn@ads.list", "format_override": "text", "processors": ["remove_comments_and_empty", "format_yaml_list"]},
    {"url": "https://github.com/ignaciocastro/a-dove-is-dumb/raw/refs/heads/main/pihole.txt", "format_override": "text", "processors": ["remove_comments_and_empty", "format_pihole"]},
]

CN_SOURCES = [
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/cn.list"},
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/steam@cn.list"},
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft@cn.list"},
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google@cn.list"},
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/win-update.list"},
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/private.list"},
]

CNIP_SOURCES = [
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cn.list"},
    {"url": "https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.list"},
]


# ================ 文本处理函数 (Python原生实现) ================
# 这些函数接收一个字符串，处理后返回一个新的字符串

def remove_comments_and_empty(text: str) -> str:
    """移除注释和空行，等同于 sed '/^#/d; /^$/d;'"""
    lines = [line for line in text.splitlines() if line.strip() and not line.strip().startswith('#')]
    return "\n".join(lines)

def add_prefix_suffix(text: str, prefix: str, suffix: str) -> str:
    """为每一行添加前缀和后缀，等同于 sed "s/^/$prefix/; s/$/$suffix/" """
    lines = [f"{prefix}{line}{suffix}" for line in text.splitlines()]
    return "\n".join(lines)

def format_pihole(text: str) -> str:
    """为pihole格式添加特定前缀"""
    return add_prefix_suffix(text, "  - '+.", "'")

def format_yaml_list(text: str) -> str:
    """标准yaml列表格式化"""
    return add_prefix_suffix(text, "  - '", "'")

# 将字符串名称映射到实际函数，便于动态调用
PROCESSORS = {
    "remove_comments_and_empty": remove_comments_and_empty,
    "format_pihole": format_pihole,
    "format_yaml_list": format_yaml_list,
}


# ================ 工具函数 ================
def init_env():
    """
    初始化环境，包括创建目录和下载Mihomo工具。
    """
    print("正在初始化环境...")
    
    # 备注：原脚本中修改系统时区的操作 (sudo timedatectl) 在Python中不推荐直接执行。
    # 我们会在Git提交时直接使用带时区的时间对象，效果相同且更安全。
    
    # 创建工作目录和输出目录
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    
    # 下载最新 mihomo
    print("下载Mihomo工具...")
    mihomo_path = WORK_DIR / "mihomo"
    if mihomo_path.exists():
        print("Mihomo 工具已存在，跳过下载。")
        return

    try:
        api_url = "https://api.github.com/repos/MetaCubeX/mihomo/releases"
        response = requests.get(api_url, timeout=30)
        response.raise_for_status()
        releases = response.json()

        download_url = ""
        for release in releases:
            if "Prerelease-Alpha" in release.get("tag_name", ""):
                for asset in release.get("assets", []):
                    if "mihomo-linux-amd64-alpha" in asset.get("name", "") and asset.get("name", "").endswith(".gz"):
                        download_url = asset.get("browser_download_url")
                        break
            if download_url:
                break
        
        if not download_url:
            print("错误：无法获取Mihomo下载链接")
            exit(1)

        print(f"从 {download_url} 下载中...")
        gz_path = WORK_DIR / "mihomo.gz"
        with requests.get(download_url, stream=True, timeout=60) as r:
            r.raise_for_status()
            with open(gz_path, 'wb') as f:
                for chunk in r.iter_content(chunk_size=8192):
                    f.write(chunk)
        
        print("解压 Mihomo...")
        with gzip.open(gz_path, 'rb') as f_in:
            with open(mihomo_path, 'wb') as f_out:
                shutil.copyfileobj(f_in, f_out)
        
        # 清理下载的压缩包
        gz_path.unlink()
        
        # 赋予执行权限
        mihomo_path.chmod(0o755)

        print("环境初始化完成")

    except Exception as e:
        print(f"环境初始化失败：{e}")
        exit(1)

def download_and_process_one(source_info: dict, index: int) -> tuple[int, str]:
    """下载并处理单个源，这是给线程池用的“小任务”"""
    url = source_info["url"]
    print(f"从 {url} 下载...")
    try:
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        content = response.text
        
        # 如果提供了特定处理链，则使用它们
        processor_names = source_info.get("processors")
        if processor_names:
            print(f"对 {url} 应用自定义处理...")
            for name in processor_names:
                content = PROCESSORS[name](content)
        else: # 否则使用默认处理
            content = remove_comments_and_empty(content)

        # 确保末尾有换行符，以便后续合并
        if not content.endswith('\n'):
            content += '\n'
        
        file_size = len(content.encode('utf-8'))
        print(f"调试: 下载并处理后内容大小: {file_size} 字节")
        if file_size == 0:
            print(f"警告: 从 {url} 获取的内容为空，可能下载或处理失败")
        
        return index, content
    except requests.RequestException as e:
        print(f"警告：下载或处理 {url} 时出错: {e}")
        return index, "" # 返回空字符串表示失败

def process_ruleset_group(name: str, rule_type: str, final_format: str, sources: list):
    """
    并行处理一组规则（如AD, CN），并转换为MRS格式。
    这等同于原脚本的 process_ruleset_parallel 函数。
    """
    print(f"处理 {name} 规则集...")
    
    # 使用线程池并行下载和处理
    results = {}
    with ThreadPoolExecutor(max_workers=10) as executor:
        # 提交所有下载任务
        future_to_source = {executor.submit(download_and_process_one, source, i): i for i, source in enumerate(sources)}
        
        # 等待任务完成并收集结果
        for future in as_completed(future_to_source):
            index, content = future.result()
            results[index] = content

    # 按原始顺序合并所有源的内容
    print(f"合并 {name} 的所有源...")
    # 确保按索引顺序合并
    ordered_contents = [results[i] for i in sorted(results.keys())]
    combined_content = "".join(ordered_contents)

    # --- 后续处理与转换 ---
    mihomo_executable = WORK_DIR / "mihomo"
    output_mrs_path = OUTPUT_DIR / f"{name}.mrs"

    if final_format == "yaml":
        lines = combined_content.splitlines()
        # 保留首行，其他行排序去重并过滤空行
        # 这完美复刻了 head -n1 和 tail -n+2 | sort -u 的逻辑
        if not lines:
            print(f"错误: {name} 规则集内容为空，跳过转换。")
            return
            
        header = lines[0]
        body_lines = sorted(list(set(filter(None, lines[1:]))))
        final_list_content = header + "\n" + "\n".join(body_lines)
        
        temp_yaml_path = WORK_DIR / f"{name}.yaml"
        temp_yaml_path.write_text(final_list_content, encoding='utf-8')
        
        print(f"调试: 合并后的 YAML 文件 '{temp_yaml_path}' 大小: {temp_yaml_path.stat().st_size} 字节，开始转换...")
        subprocess.run([str(mihomo_executable), "convert-ruleset", rule_type, "yaml", str(temp_yaml_path), str(output_mrs_path)], check=True)
        # temp_yaml_path.unlink() # 可以选择清理临时文件

    else: # text 格式
        # 删除空行后排序去重
        lines = filter(None, combined_content.splitlines())
        unique_sorted_lines = sorted(list(set(lines)))
        final_text_content = "\n".join(unique_sorted_lines)
        
        temp_text_path = WORK_DIR / f"{name}.text"
        temp_text_path.write_text(final_text_content, encoding='utf-8')

        print(f"调试: 合并后的 TEXT 文件 '{temp_text_path}' 大小: {temp_text_path.stat().st_size} 字节，开始转换...")
        subprocess.run([str(mihomo_executable), "convert-ruleset", rule_type, "text", str(temp_text_path), str(output_mrs_path)], check=True)
        # temp_text_path.unlink() # 可以选择清理临时文件

    print(f"{name} 规则集处理完成")


def commit_changes():
    """提交更改到Git仓库"""
    print("提交更改到Git仓库...")
    
    if not shutil.which("git"):
        print("错误：未找到 'git' 命令，无法提交。")
        return

    try:
        # 使用Python的datetime获取带时区的时间
        shanghai_tz = ZoneInfo("Asia/Shanghai")
        commit_time = datetime.now(shanghai_tz).strftime('%Y-%m-%d %H:%M:%S')
        commit_message = f"{commit_time} 更新mrs规则"

        # 执行Git命令
        # cwd参数指定了命令在哪个目录下执行
        subprocess.run(["git", "config", "--local", "user.email", "actions@github.com"], cwd=REPO_DIR, check=True)
        subprocess.run(["git", "config", "--local", "user.name", "GitHub Actions"], cwd=REPO_DIR, check=True)
        subprocess.run(["git", "pull", "origin", "main"], cwd=REPO_DIR, check=True)
        subprocess.run(["git", "add", "mrs/*"], cwd=REPO_DIR, check=True)
        
        # commit可能会因为没有变更而失败，所以我们不使用check=True，而是检查返回码
        result = subprocess.run(["git", "commit", "-m", commit_message], cwd=REPO_DIR, capture_output=True, text=True)
        if result.returncode != 0:
            if "nothing to commit" in result.stdout or "无文件要提交" in result.stdout:
                print("没有需要提交的更改")
            else:
                print(f"Git commit 失败: {result.stderr}")
        else:
            print("提交完成")
            # 注意：原脚本没有push，这里也保持一致。push操作通常由CI/CD流程文件定义。

    except FileNotFoundError:
        print(f"错误: Git仓库目录 '{REPO_DIR}' 不存在。")
    except subprocess.CalledProcessError as e:
        print(f"执行Git命令时出错: {e}")
    except Exception as e:
        print(f"提交时发生未知错误: {e}")


# ================ 主执行流程 ================
def main():
    """主函数，负责调度所有任务"""
    init_env()
    
    # 使用线程池并行处理三个大的规则集
    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = [
            executor.submit(process_ruleset_group, "ad", "domain", "yaml", AD_SOURCES),
            executor.submit(process_ruleset_group, "cn", "domain", "text", CN_SOURCES),
            executor.submit(process_ruleset_group, "cnIP", "ipcidr", "text", CNIP_SOURCES)
        ]
        # 等待所有规则集处理完成
        for future in as_completed(futures):
            try:
                future.result() # 如果任务中发生异常，这里会抛出
            except Exception as e:
                print(f"一个规则集处理任务失败: {e}")
    
    commit_changes()
    
    print("所有操作已完成，喵~")

if __name__ == "__main__":
    main()