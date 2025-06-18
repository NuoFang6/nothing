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
from zoneinfo import ZoneInfo

# ================ 配置部分 (【核心修正处】) ================
# 【修正】修改路径定义，确保它们指向正确的位置
#
# 假设您的目录结构是这样：
# .
# ├── nothing/      <-- Git 仓库根目录
# │   └── mrs/      <-- 输出目录
# └── a_folder/     <-- 脚本存放在任何文件夹
#     └── this_script.py

# 获取脚本文件所在的目录
SCRIPT_DIR = Path(__file__).resolve().parent

# 使用原 Shell 脚本的相对路径逻辑 `../` 来定义
# .parent 会返回上一级目录，效果等同于 `../`
# 这种方式更灵活，不依赖固定的 `scripts` 文件夹名
WORK_DIR = SCRIPT_DIR / ".." / "tmp"
REPO_DIR = SCRIPT_DIR / ".." / "nothing"
OUTPUT_DIR = REPO_DIR / "mrs"

# 打印出最终解析的路径，方便主人调试确认
print(f"工作目录 (WORK_DIR): {WORK_DIR.resolve()}")
print(f"仓库目录 (REPO_DIR): {REPO_DIR.resolve()}")
print(f"输出目录 (OUTPUT_DIR): {OUTPUT_DIR.resolve()}")
print("-" * 30)


# --- 数据源配置 (与之前相同) ---
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

# ... 后续所有函数 (remove_comments_and_empty, init_env, process_ruleset_group, etc.) 
# ... 都与上一版完全相同，无需任何修改 ...

# ================ 文本处理函数 (与之前相同) ================
def remove_comments_and_empty(text: str) -> str:
    lines = [line for line in text.splitlines() if line.strip() and not line.strip().startswith('#')]
    return "\n".join(lines)

def add_prefix_suffix(text: str, prefix: str, suffix: str) -> str:
    lines = [f"{prefix}{line}{suffix}" for line in text.splitlines()]
    return "\n".join(lines)

def format_pihole(text: str) -> str:
    return add_prefix_suffix(text, "  - '+.", "'")

def format_yaml_list(text: str) -> str:
    return add_prefix_suffix(text, "  - '", "'")

PROCESSORS = {
    "remove_comments_and_empty": remove_comments_and_empty,
    "format_pihole": format_pihole,
    "format_yaml_list": format_yaml_list,
}

# ================ 工具函数 (init_env 和 download_and_process_one 与之前相同) ================
def init_env():
    print("正在初始化环境...")
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    WORK_DIR.mkdir(parents=True, exist_ok=True)
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
        with gzip.open(gz_path, 'rb') as f_in:
            with open(mihomo_path, 'wb') as f_out:
                shutil.copyfileobj(f_in, f_out)
        gz_path.unlink()
        mihomo_path.chmod(0o755)
        print("环境初始化完成")
    except Exception as e:
        print(f"环境初始化失败：{e}")
        exit(1)

def download_and_process_one(source_info: dict, index: int) -> tuple[int, str]:
    url = source_info["url"]
    print(f"从 {url} 下载...")
    try:
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        content = response.text
        processor_names = source_info.get("processors")
        if processor_names:
            print(f"对 {url} 应用自定义处理...")
            for name in processor_names:
                content = PROCESSORS[name](content)
        else:
            content = remove_comments_and_empty(content)
        if not content.endswith('\n'):
            content += '\n'
        file_size = len(content.encode('utf-8'))
        print(f"调试: 下载并处理后内容大小: {file_size} 字节")
        if file_size == 0:
            print(f"警告: 从 {url} 获取的内容为空，可能下载或处理失败")
        return index, content
    except requests.RequestException as e:
        print(f"警告：下载或处理 {url} 时出错: {e}")
        return index, ""

def process_ruleset_group(name: str, rule_type: str, final_format: str, sources: list):
    print(f"处理 {name} 规则集...")
    
    results = {}
    with ThreadPoolExecutor(max_workers=10) as executor:
        future_to_source = {executor.submit(download_and_process_one, source, i): i for i, source in enumerate(sources)}
        for future in as_completed(future_to_source):
            index, content = future.result()
            results[index] = content
    ordered_contents = [results[i] for i in sorted(results.keys())]
    combined_content = "".join(ordered_contents)

    mihomo_executable = WORK_DIR / "mihomo"
    temp_source_path = WORK_DIR / f"{name}.{final_format}"
    final_source_path = OUTPUT_DIR / f"{name}.{final_format}"
    final_mrs_path = OUTPUT_DIR / f"{name}.mrs"

    if final_format == "yaml":
        lines = combined_content.splitlines()
        if not lines:
            print(f"错误: {name} 规则集内容为空，跳过转换。")
            return None
        header = lines[0]
        body_lines = sorted(list(set(filter(None, lines[1:]))))
        final_list_content = header + "\n" + "\n".join(body_lines)
        temp_source_path.write_text(final_list_content, encoding='utf-8')
    else:
        lines = filter(None, combined_content.splitlines())
        unique_sorted_lines = sorted(list(set(lines)))
        final_text_content = "\n".join(unique_sorted_lines)
        temp_source_path.write_text(final_text_content, encoding='utf-8')

    print(f"调试: 合并后的源文件 '{temp_source_path}' 大小: {temp_source_path.stat().st_size} 字节，开始转换...")
    
    try:
        temp_mrs_path = WORK_DIR / f"{name}.mrs"
        subprocess.run(
            [str(mihomo_executable), "convert-ruleset", rule_type, final_format, str(temp_source_path), str(temp_mrs_path)],
            check=True, capture_output=True, text=True
        )
        shutil.move(str(temp_source_path), str(final_source_path))
        shutil.move(str(temp_mrs_path), str(final_mrs_path))
        print(f"{name} 规则集处理完成，文件已移至 {OUTPUT_DIR}")
        return [final_source_path, final_mrs_path]
    except subprocess.CalledProcessError as e:
        print(f"错误: Mihomo 转换 {name} 失败！")
        print(f"命令: {e.cmd}")
        print(f"返回码: {e.returncode}")
        print(f"输出: {e.stdout}")
        print(f"错误输出: {e.stderr}")
        return None
    except Exception as e:
        print(f"处理 {name} 规则集时发生未知错误: {e}")
        return None

def commit_changes():
    print("提交更改到Git仓库...")
    if not shutil.which("git"):
        print("错误：未找到 'git' 命令，无法提交。")
        return
    try:
        shanghai_tz = ZoneInfo("Asia/Shanghai")
        commit_time = datetime.now(shanghai_tz).strftime('%Y-%m-%d %H:%M:%S')
        commit_message = f"{commit_time} 更新mrs规则"
        subprocess.run(["git", "config", "--local", "user.email", "actions@github.com"], cwd=REPO_DIR, check=True)
        subprocess.run(["git", "config", "--local", "user.name", "GitHub Actions"], cwd=REPO_DIR, check=True)
        subprocess.run(["git", "pull", "origin", "main"], cwd=REPO_DIR, check=True)
        subprocess.run(["git", "add", "mrs/*"], cwd=REPO_DIR, check=True)
        result = subprocess.run(["git", "commit", "-m", commit_message], cwd=REPO_DIR, capture_output=True, text=True)
        if result.returncode != 0:
            if "nothing to commit" in result.stdout or "无文件要提交" in result.stdout:
                print("没有需要提交的更改")
            else:
                print(f"Git commit 失败: {result.stderr}")
        else:
            print("提交完成")
    except FileNotFoundError:
        print(f"错误: Git仓库目录 '{REPO_DIR}' 不存在。")
    except subprocess.CalledProcessError as e:
        print(f"执行Git命令时出错: {e}")
    except Exception as e:
        print(f"提交时发生未知错误: {e}")

# ================ 主执行流程 (含最终检查) ================
def main():
    """主函数，负责调度所有任务，并包含最终检查"""
    init_env()
    
    tasks_to_run = [
        {"name": "ad", "type": "domain", "format": "yaml", "sources": AD_SOURCES},
        {"name": "cn", "type": "domain", "format": "text", "sources": CN_SOURCES},
        {"name": "cnIP", "type": "ipcidr", "format": "text", "sources": CNIP_SOURCES},
    ]
    
    all_generated_files = []
    
    with ThreadPoolExecutor(max_workers=3) as executor:
        futures = {
            executor.submit(process_ruleset_group, task["name"], task["type"], task["format"], task["sources"]): task 
            for task in tasks_to_run
        }
        
        for future in as_completed(futures):
            generated_files = future.result()
            if generated_files:
                all_generated_files.extend(generated_files)
            else:
                task_name = futures[future]["name"]
                print(f"警告：任务 {task_name} 未能成功生成文件。")

    print("\n--- 开始最终文件检查 ---")
    all_ok = True
    if not all_generated_files:
        print("错误：没有任何文件被生成！")
        all_ok = False
    else:
        for file_path in all_generated_files:
            if file_path.exists() and file_path.stat().st_size > 0:
                print(f"✅ 文件检查成功: {file_path} (大小: {file_path.stat().st_size} 字节)")
            else:
                print(f"❌ 文件检查失败: {file_path} 不存在或为空！")
                all_ok = False
    
    if all_ok:
        print("所有文件均已正确生成和替换。")
        commit_changes()
    else:
        print("\n由于文件检查失败，跳过Git提交。请检查上面的错误日志。")
        exit(1)
    
    print("\n所有操作已完成，喵~")

if __name__ == "__main__":
    main()