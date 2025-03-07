import yaml

source_file = "list.meta.yml"
filtered_file = "list.filtered.meta.yaml"

# 定义需要过滤掉的端口号列表
# ports_to_filter = {
#     443,
#     2053,
#     2083,
#     2087,
#     2096,
#     8443,
#     80,
#     8080,
#     8880,
#     2052,
#     2082,
#     2086,
#     2095,
# }

# 读取 YAML 文件
with open(source_file, "r") as f:
    data = yaml.safe_load(f)

# 用于存储已出现的 (server, port) 和 (server, type) 组合
seen_combinations = set()
seen_server_type_combinations = set()

# 遍历 proxies 数组，删除 port 属于 ports_to_filter 的项，同时去重
filtered_proxies = []
for proxy in data.get("proxies", []):
    server = proxy.get("server")
    port = proxy.get("port")
    proxy_type = proxy.get("type")
    network = proxy.get("network")

    # 将 port 转换为整数进行比较（避免字符串 '2095' 和数字 2095 不匹配）
    try:
        port = int(port)
    except (ValueError, TypeError):
        continue  # 如果端口无法转换为数字，则跳过

    # # 跳过要过滤的端口
    # if port in ports_to_filter and proxy.get("network") == "ws":
    #     continue

    if proxy_type == "trojan":
        continue

    if network == "ws" and proxy_type == "vmess":
        continue

    if network == "ws" and proxy_type == "vless":
        continue

    # 去重 (server, port) 组合
    if (server, port) in seen_combinations:
        continue

    if proxy.get("obfs") == "none":
        continue

    # # 去重 (server, type) 组合
    # if (server, proxy_type) in seen_server_type_combinations:
    #     continue

    # 添加当前组合到对应的去重集合
    seen_combinations.add((server, port))
    # seen_server_type_combinations.add((server, proxy_type))

    # 保留当前 proxy
    filtered_proxies.append(proxy)

# 将过滤和去重后的数据重新赋值给 data['proxies']
data["proxies"] = filtered_proxies

# 按照英文字母表顺序排序
data["proxies"].sort(key=lambda x: x.get("type", ""))


# 删除 proxy-groups 字段
if "proxy-groups" in data:
    del data["proxy-groups"]

# 将处理后的数据写入新的文件，确保字符不被转义
with open(filtered_file, "w") as f:
    yaml.safe_dump(data, f, default_flow_style=False, allow_unicode=True)
    # 追加内容到文件末尾
    additional_content = """
204Set: &204Set
  url: "https://www.youtube.com/generate_204"
  expected-status: 204
  interval: 450
  timeout: 10000
  lazy: true

groupsSet: &groupsSet
  tfo: true
  mptcp: true
  tolerance: 40
  max-failed-times: 2
  <<: *204Set

proxy-groups:
  - name: PROXY
    type: select
    proxies:
        - 🚀自动选择
    include-all-proxies: true
    <<: *groupsSet

  - name: 🚀自动选择
    type: url-test
    include-all-proxies: true
    <<: *groupsSet
    """

    with open(filtered_file, "a") as f:
        f.write(additional_content)

print("过滤、去重、保存到新文件 完成！")
