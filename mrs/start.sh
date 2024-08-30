cd ..
mkdir tmp && cd tmp

# 下载最新 mihomo
wget -q -O mihomo.gz "$(curl -s https://api.github.com/repos/MetaCubeX/mihomo/releases | jq -r '.[] | select(.tag_name | test("Prerelease-Alpha")) | .assets[] | select(.name | test("mihomo-linux-amd64-alpha-.*\\.gz")) | .browser_download_url')"
gunzip mihomo.gz
chmod +x mihomo

# ** ad.mrs **
# antiAD
#去除注释和空行
#保证结尾有换行符
wget -q -O - https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-clash.yaml |
    sed '/^#/d; /^$/d;' |
    sed -e '$a\' >>ad

# AdRules
#转为yaml格式
wget -q -O - https://raw.githubusercontent.com/Cats-Team/AdRules/main/adrules_domainset.txt |
    sed "/^#/d; /^$/d;" |
    sed "s/^/  - '/; s/$/'/" |
    sed -e '$a\' >>ad

# hagezi pro.mini
#转为yaml格式,添加 +.
wget -q -O - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt |
    sed "/^#/d; /^$/d;" |
    sed "s/^/  - '+./; s/$/'/" >>ad
#合并并去重
cat ad | awk '!seen[$0]++' | sed "/^$/d" >ad.yaml
# 转换为 mrs
./mihomo convert-ruleset domain yaml ad.yaml ad.mrs
# 移动覆盖结果至仓库
mv -f ad.yaml ad.mrs ../nothing/mrs/

# ** DoHdomains.mrs **
wget -q -O - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/doh-onlydomains.txt |
    sed "/^#/d; /^$/d;" |
    sed "s/^/+./" >>DoHdomains.text
./mihomo convert-ruleset domain text DoHdomains.text DoHdomains.mrs
mv -f DoHdomains.text DoHdomains.mrs ../nothing/mrs/

# ** tif.mrs **
wget -q -O - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt |
    sed "/^#/d; /^$/d;" |
    sed "s/^/+./" >>tif.text
./mihomo convert-ruleset domain text tif.text tif.mrs
mv -f tif.text tif.mrs ../nothing/mrs/

# ** cn.mrs **
for url in \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/steam@cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft@cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google@cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/win-update.list; do
    wget -q -O - "$url" | sed -e '$a\' >>cn
done
cat cn | awk '!seen[$0]++' | sed "/^$/d" >cn.text
./mihomo convert-ruleset domain text cn.text cn.mrs
mv -f cn.text cn.mrs ../nothing/mrs/

# ** cnIP.mrs **
for url in \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geoip/private.list; do
    wget -q -O - "$url" | sed -e '$a\' >>cnIP
done
cat cnIP | awk '!seen[$0]++' | sed "/^$/d" >cnIP.text
./mihomo convert-ruleset ipcidr text cnIP.text cnIP.mrs
mv -f cnIP.text cnIP.mrs ../nothing/mrs/

# ** 完事提交修改 **
cd ../nothing/
git config --local user.email "actions@github.com"
git config --local user.name "GitHub Actions"
git pull origin main
git add ./mrs/*
git commit -m "$(date '+%Y-%m-%d %H:%M:%S') 更新mrs规则" || true
