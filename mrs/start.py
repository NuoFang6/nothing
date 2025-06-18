#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import requests
import gzip
import shutil
import subprocess
import json
import logging # 🐾 新增：导入日志模块
import hashlib # 🐾 新增：导入哈希计算模块
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from zoneinfo import ZoneInfo

# ================ 日志配置 ================
# 🐾 新增：配置日志记录器
def setup_logging(log_file_path: Path):
    """配置日志，同时输出到控制台和文件"""
    # log_file_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(levelname)s - %(message)s',
        handlers=[
            # logging.FileHandler(log_file_path, encoding='utf-8'),
            logging.StreamHandler() # 同时输出到控制台
        ]
    )

# ================ 配置部分 ================
BASE_DIR = Path(__file__).parent
WORK_DIR = BASE_DIR / "tmp"
REPO_DIR = BASE_DIR / "nothing"
OUTPUT_DIR = REPO_DIR / "mrs"
LOG_FILE = WORK_DIR / "script_run.log" # 🐾 新增：定义日志文件路径

# --- 数据源配置 (保持不变) ---
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

# ================ 文本处理函数 (保持不变) ================
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

# ================ 工具函数 ================
# 🐾 新增：计算文件哈希值的辅助函数
def get_file_sha256(file_path: Path) -> str | None:
    """计算文件的SHA256哈希值，如果文件不存在则返回None"""
    if not file_path.exists():
        return None
    sha256_hash = hashlib.sha256()
    with open(file_path, "rb") as f:
        # Read and update hash string value in blocks of 4K
        for byte_block in iter(lambda: f.read(4096), b""):
            sha256_hash.update(byte_block)
    return sha256_hash.hexdigest()

def init_env():
    """初始化环境"""
    logging.info("正在初始化环境...")
    WORK_DIR.mkdir(parents=True, exist_ok=True)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    
    mihomo_path = WORK_DIR / "mihomo"
    if mihomo_path.exists():
        logging.info("Mihomo 工具已存在，跳过下载。")
        return

    try:
        api_url = "https://api.github.com/repos/MetaCubeX/mihomo/releases"
        logging.info(f"正在从GitHub API获取Mihomo发布信息: {api_url}")
        response = requests.get(api_url, timeout=30)
        response.raise_for_status()
        releases = response.json()
        
        # ... (下载逻辑保持不变，但打印改为了日志记录)
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
            logging.error("无法获取Mihomo下载链接")
            exit(1)

        logging.info(f"从 {download_url} 下载中...")
        gz_path = WORK_DIR / "mihomo.gz"
        with requests.get(download_url, stream=True, timeout=60) as r:
            r.raise_for_status()
            with open(gz_path, 'wb') as f: shutil.copyfileobj(r.raw, f) # type: ignore
        
        logging.info("解压 Mihomo...")
        with gzip.open(gz_path, 'rb') as f_in:
            with open(mihomo_path, 'wb') as f_out: shutil.copyfileobj(f_in, f_out)
        
        gz_path.unlink()
        mihomo_path.chmod(0o755)
        logging.info("环境初始化完成")

    except Exception as e:
        logging.critical(f"环境初始化失败：{e}")
        exit(1)

def download_and_process_one(source_info: dict, index: int) -> tuple[int, str]:
    """下载并处理单个源"""
    url = source_info["url"]
    logging.info(f"开始下载: {url}")
    try:
        response = requests.get(url, timeout=30)
        response.raise_for_status()
        content = response.text
        
        processor_names = source_info.get("processors")
        if processor_names:
            logging.info(f"对 {url} 应用自定义处理: {', '.join(processor_names)}")
            for name in processor_names: content = PROCESSORS[name](content)
        else:
            content = remove_comments_and_empty(content)

        if not content.endswith('\n'): content += '\n'
        
        file_size = len(content.encode('utf-8'))
        logging.info(f"下载并处理完成: {url} (大小: {file_size} 字节)")
        if file_size == 0:
            logging.warning(f"从 {url} 获取的内容为空")
        
        return index, content
    except requests.RequestException as e:
        logging.warning(f"下载或处理失败: {url} - 错误: {e}")
        return index, ""

def process_ruleset_group(name: str, rule_type: str, final_format: str, sources: list):
    """并行处理一组规则，并验证文件更新"""
    logging.info(f"开始处理 {name} 规则集...")
    
    results = {}
    with ThreadPoolExecutor(max_workers=10) as executor:
        future_to_source = {executor.submit(download_and_process_one, source, i): i for i, source in enumerate(sources)}
        for future in as_completed(future_to_source):
            index, content = future.result()
            results[index] = content

    logging.info(f"合并 {name} 的所有源...")
    ordered_contents = [results[i] for i in sorted(results.keys())]
    combined_content = "".join(ordered_contents)

    if not combined_content.strip():
        logging.error(f"{name} 规则集内容为空，跳过此规则集的处理。")
        return
        
    mihomo_executable = WORK_DIR / "mihomo"
    # 🐾 修改：使用临时文件来存放最终的 .mrs 文件，以便比较
    temp_mrs_path = WORK_DIR / f"{name}.mrs.tmp"
    final_mrs_path = OUTPUT_DIR / f"{name}.mrs"

    # --- 文本预处理逻辑 (将 print 改为 logging.debug) ---
    temp_processed_path = WORK_DIR / f"{name}.{'yaml' if final_format == 'yaml' else 'text'}"
    if final_format == "yaml":
        lines = combined_content.splitlines()
        header = lines[0]
        body_lines = sorted(list(set(filter(None, lines[1:]))))
        final_list_content = header + "\n" + "\n".join(body_lines)
        temp_processed_path.write_text(final_list_content, encoding='utf-8')
    else:
        lines = filter(None, combined_content.splitlines())
        unique_sorted_lines = sorted(list(set(lines)))
        final_text_content = "\n".join(unique_sorted_lines)
        temp_processed_path.write_text(final_text_content, encoding='utf-8')

    logging.info(f"合并后的文件 '{temp_processed_path.name}' 大小: {temp_processed_path.stat().st_size} 字节，开始转换...")
    
    # --- 调用 mihomo 进行转换 ---
    try:
        subprocess.run(
            [str(mihomo_executable), "convert-ruleset", rule_type, final_format, str(temp_processed_path), str(temp_mrs_path)],
            check=True, capture_output=True, text=True
        )
    except subprocess.CalledProcessError as e:
        logging.error(f"Mihomo 转换失败 for {name}: {e.stderr}")
        return

    # --- 🐾 核心改进：文件更新验证 ---
    old_hash = get_file_sha256(final_mrs_path)
    new_hash = get_file_sha256(temp_mrs_path)

    if old_hash == new_hash:
        logging.info(f"✔️ 文件 '{final_mrs_path.name}' 内容未发生变化，无需替换。 (SHA256: {new_hash[:12]}...)") # type: ignore
        temp_mrs_path.unlink() # 删除临时生成的新文件
    else:
        logging.info(f"✨ 文件 '{final_mrs_path.name}' 已更新！正在替换...")
        logging.info(f"   旧哈希: {old_hash[:12] if old_hash else 'N/A'}...")
        logging.info(f"   新哈希: {new_hash[:12]}...") # type: ignore
        shutil.move(temp_mrs_path, final_mrs_path) # 用新文件覆盖旧文件

    # 清理中间文件
    temp_processed_path.unlink()
    logging.info(f"✅ {name} 规则集处理完成。")

def commit_changes():
    """提交更改到Git仓库"""
    logging.info("准备提交更改到Git仓库...")
    
    if not shutil.which("git"):
        logging.error("未找到 'git' 命令，无法提交。")
        return

    try:
        shanghai_tz = ZoneInfo("Asia/Shanghai")
        commit_time = datetime.now(shanghai_tz).strftime('%Y-%m-%d %H:%M:%S')
        commit_message = f"{commit_time} 更新mrs规则"

        subprocess.run(["git", "-C", str(REPO_DIR), "config", "--local", "user.email", "actions@github.com"], check=True)
        subprocess.run(["git", "-C", str(REPO_DIR), "config", "--local", "user.name", "GitHub Actions"], check=True)
        logging.info("正在拉取远程仓库更新...")
        subprocess.run(["git", "-C", str(REPO_DIR), "pull", "origin", "main"], check=True)
        logging.info("添加新生成的文件到暂存区...")
        subprocess.run(["git", "-C", str(REPO_DIR), "add", "mrs/*"], check=True)
        
        result = subprocess.run(["git", "-C", str(REPO_DIR), "commit", "-m", commit_message], capture_output=True, text=True)
        if result.returncode == 0:
            logging.info("Git commit成功！")
            logging.info(result.stdout)
        elif "nothing to commit" in result.stdout or "无文件要提交" in result.stdout:
            logging.info("✔️ Git仓库中没有需要提交的更改。")
        else:
            logging.error(f"Git commit 失败: {result.stderr}")

    except FileNotFoundError:
        logging.error(f"Git仓库目录 '{REPO_DIR}' 不存在。")
    except subprocess.CalledProcessError as e:
        logging.error(f"执行Git命令时出错: {e.stderr}")
    except Exception as e:
        logging.error(f"提交时发生未知错误: {e}")

# ================ 主执行流程 ================
def main():
    """主函数，负责调度所有任务"""
    setup_logging(LOG_FILE) # 🐾 新增：在开始时设置好日志
    logging.info("================== 脚本开始运行 ==================")
    
    try:
        init_env()
        
        with ThreadPoolExecutor(max_workers=3) as executor:
            futures = [
                executor.submit(process_ruleset_group, "ad", "domain", "yaml", AD_SOURCES),
                executor.submit(process_ruleset_group, "cn", "domain", "text", CN_SOURCES),
                executor.submit(process_ruleset_group, "cnIP", "ipcidr", "text", CNIP_SOURCES)
            ]
            for future in as_completed(futures):
                try:
                    future.result()
                except Exception as e:
                    logging.error(f"一个规则集处理任务执行时出现严重错误: {e}", exc_info=True)
        
        commit_changes()
    
    except Exception as e:
        logging.critical(f"脚本在主流程中遭遇致命错误，已终止: {e}", exc_info=True)
    finally:
        logging.info("================== 脚本运行结束 ==================\n")


if __name__ == "__main__":
    main()