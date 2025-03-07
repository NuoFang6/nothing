# 修改时区
sudo timedatectl set-timezone 'Asia/Shanghai'

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

# # AdRules
# #转为yaml格式
# wget -q -O - https://raw.githubusercontent.com/Cats-Team/AdRules/main/adrules_domainset.txt |
#     sed "/^#/d; /^$/d;" |
#     sed "s/^/  - '/; s/$/'/" |
#     sed -e '$a\' >>ad

# category-httpdns-cn@ads.list
#转为yaml格式
wget -q -O - https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-httpdns-cn@ads.list |
    sed "/^#/d; /^$/d;" |
    sed "s/^/  - '/; s/$/'/" |
    sed -e '$a\' >>ad

# # Xiaomi 跟踪器
# wget -q -O - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/native.xiaomi.txt |
#     sed "/^#/d; /^$/d;" |
#     sed "s/^/  - '+./; s/$/'/" |
#     sed -e '$a\' >>ad

# adobe 跟踪器
wget -q -O - https://github.com/ignaciocastro/a-dove-is-dumb/raw/refs/heads/main/pihole.txt |
    sed "/^#/d; /^$/d;" |
    sed "s/^/  - '+./; s/$/'/" |
    sed -e '$a\' >>ad

# hagezi pro.mini
#转为yaml格式,添加 +.
# wget -q -O - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/pro.mini-onlydomains.txt |
#     sed "/^#/d; /^$/d;" |
#     sed "s/^/  - '+./; s/$/'/" |
#     sed -e '$a\' >>ad

#合并并去重
cat ad | awk '!seen[$0]++' | sed "/^$/d" >ad.yaml
# 转换为 mrs
./mihomo convert-ruleset domain yaml ad.yaml ad.mrs
# 移动覆盖结果至仓库
mv -f ad.yaml ad.mrs ../nothing/mrs/



# # ** DoHdomains.mrs **
# wget -q -O - https://github.com/MetaCubeX/meta-rules-dat/raw/refs/heads/meta/geo/geosite/category-httpdns-cn.list |
#     sed "/^#/d; /^$/d;"|
#     sed -e '$a\' >>DoHdomains
# wget -q -O - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/doh-onlydomains.txt |
#     sed "/^#/d; /^$/d;" |
#     sed "s/^/+./" >>DoHdomains
# cat DoHdomains | awk '!seen[$0]++' | sed "/^$/d" >DoHdomains.text
# ./mihomo convert-ruleset domain text DoHdomains.text DoHdomains.mrs
# mv -f DoHdomains.text DoHdomains.mrs ../nothing/mrs/

# # ** tif.mrs **
# wget -q -O - https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/tif-onlydomains.txt |
#     sed "/^#/d; /^$/d;" |
#     sed "s/^/+./" >>tif.text
# ./mihomo convert-ruleset domain text tif.text tif.mrs
# mv -f tif.text tif.mrs ../nothing/mrs/


# ** cn.mrs **
for url in \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/steam@cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/microsoft@cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/google@cn.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/win-update.list \
    https://github.com/MetaCubeX/meta-rules-dat/raw/meta/geo/geosite/private.list; do
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


# # ** hijacking.yaml **
# for url in \
#     https://github.com/blackmatrix7/ios_rule_script/raw/master/rule/Clash/Hijacking/Hijacking_No_Resolve.yaml; do
#     wget -q -O - "$url" | sed '/^#/d; /^$/d;' | sed -e '$a\' >>hijacking
# done
# # 追加yaml列表内容至hijacking末尾
# cat <<EOF >>hijacking
#   - DOMAIN-SUFFIX,sdkconf.avlyun.com
#   - DOMAIN-SUFFIX,ixav-cse.avlyun.com
#   - DOMAIN-SUFFIX,miav-cse.avlyun.com
#   - DOMAIN-SUFFIX,miui-fxcse.avlyun.com
#   - DOMAIN-SUFFIX,api.sec.miui.com
#   - DOMAIN-SUFFIX,adv.sec.miui.com
#   - DOMAIN-SUFFIX,srv.sec.miui.com
#   - DOMAIN-SUFFIX,xlmc.sec.miui.com
#   - DOMAIN-SUFFIX,data.sec.miui.com
#   - DOMAIN-SUFFIX,port.sec.miui.com
#   - DOMAIN-SUFFIX,flash.sec.miui.com
#   - DOMAIN-SUFFIX,avlyun.sec.miui.com
#   - DOMAIN-SUFFIX,auth.be.sec.miui.com
#   - DOMAIN-SUFFIX,avlyun.sec.intl.miui.com
#   - DOMAIN-SUFFIX,a0.app.xiaomi.com
#   - DOMAIN-SUFFIX,hybrid.xiaomi.com
#   - DOMAIN-SUFFIX,cn.app.chat.xiaomi.net
#   - DOMAIN-SUFFIX,api.installer.xiaomi.com
#   - DOMAIN-SUFFIX,a.hl.mi.com
#   - DOMAIN-SUFFIX,api.jr.mi.com
#   - DOMAIN-SUFFIX,etl-xlmc-ssl.sandai.net
#   - DOMAIN-SUFFIX,tmfsdk.m.qq.com
#   - PROCESS-NAME-REGEX,antifraud|hicore
#   - DOMAIN-KEYWORD,96110
#   - DOMAIN-KEYWORD,fqzpt
#   - DOMAIN-KEYWORD,fzlmn
#   - DOMAIN-KEYWORD,chanct
#   - DOMAIN-KEYWORD,fanzha
#   - DOMAIN-KEYWORD,gjfzpt
#   - DOMAIN-KEYWORD,ifcert
#   - DOMAIN-KEYWORD,hicore
#   - DOMAIN-KEYWORD,bestmind
#   - DOMAIN-KEYWORD,hei-tong
#   - DOMAIN-KEYWORD,appbushou
#   - DOMAIN-KEYWORD,loongteam
#   - DOMAIN-KEYWORD,himindtech
#   - DOMAIN-KEYWORD,tendyron
#   - DOMAIN-SUFFIX,f3322.net
#   - DOMAIN-SUFFIX,cert.org.cn
#   - DOMAIN-SUFFIX,cnvd.org.cn
#   - DOMAIN-SUFFIX,certlab.org
#   - DOMAIN-SUFFIX,anva.org.cn
#   - DOMAIN-SUFFIX,fhss.com.cn
#   - DOMAIN-SUFFIX,hailiangyun.cn
#   - DOMAIN-SUFFIX,ics-cert.org.cn
#   - IP-CIDR,36.135.82.110/32,no-resolve
#   - IP-CIDR,39.102.194.95/32,no-resolve
#   - IP-CIDR,61.135.15.244/32,no-resolve
#   - IP-CIDR,61.160.148.90/32,no-resolve
#   - IP-CIDR,101.35.177.86/32,no-resolve
#   - IP-CIDR,106.74.25.198/32,no-resolve
#   - IP-CIDR,112.15.232.43/32,no-resolve
#   - IP-CIDR,124.236.16.201/32,no-resolve
#   - IP-CIDR,157.148.47.204/32,no-resolve
#   - IP-CIDR,182.43.124.6/32,no-resolve
#   - IP-CIDR,211.137.117.149/32,no-resolve
#   - IP-CIDR,211.139.145.129/32,no-resolve
#   - IP-CIDR,219.143.187.136/32,no-resolve
#   - IP-CIDR,221.180.160.221/32,no-resolve
#   - IP-CIDR,221.228.32.13/32,no-resolve
#   - IP-CIDR,223.75.236.241/32,no-resolve
# EOF
# cat hijacking | awk '!seen[$0]++' | sed "/^$/d" >hijacking.yaml
# mv -f hijacking.yaml ../nothing/mrs/

# ** 完事提交修改 **
cd ../nothing/
git config --local user.email "actions@github.com"
git config --local user.name "GitHub Actions"
git pull origin main
git add ./mrs/*
git commit -m "$(date '+%Y-%m-%d %H:%M:%S') 更新mrs规则" || true
