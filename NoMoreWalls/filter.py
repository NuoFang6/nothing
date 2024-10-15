import yaml

source_file = "source.yaml"
filtered_file = "list.filtered.meta.yaml"

# 定义需要过滤掉的端口号列表
ports_to_filter = {
    443,
    2053,
    2083,
    2087,
    2096,
    8443,
    80,
    8080,
    8880,
    2052,
    2082,
    2086,
    2095,
}

# 读取 YAML 文件
with open(source_file, "r") as f:
    data = yaml.safe_load(f)

# 用于存储已出现的 (server, port) 组合
seen_combinations = set()

# 遍历 proxies 数组，删除 port 属于 ports_to_filter 的项，同时去重
filtered_proxies = []
for proxy in data.get("proxies", []):
    server = proxy.get("server")
    port = proxy.get("port")

    # 跳过要过滤的端口
    if port in ports_to_filter:
        continue

    # 如果 (server, port) 组合没见过，添加到 filtered_proxies 中
    if (server, port) not in seen_combinations:
        filtered_proxies.append(proxy)
        seen_combinations.add((server, port))

# 将去重和过滤后的数据重新赋值给 data['proxies']
data["proxies"] = filtered_proxies

# 将处理后的数据写入新的文件
with open(filtered_file, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False)

print("过滤、去重、保存到新文件 完成！")
