# luci-app-nodemanager

管理 `/etc/nikki/profiles/config.yaml` 的 LuCI 插件。

## 功能
- 节点增删改查（域名/IP + 端口 + 账号密码），并同步 rules 中的 `SRC-IP-CIDR` 绑定；
- 机场（proxy-providers）增删改，URL 必须 http/https；
- DNS `nameserver` 仅 IPv4，其他 DNS 选项原样保留；
- 日志查看（`/etc/nikki/nodemanager.log` 或 `logread`）；
- i18n：中文、英文；
- GitHub Action 云编译：OpenWrt 24.10.x，mediatek/filogic。

## 安装
```sh
opkg install luci-app-nodemanager_*.ipk
/etc/init.d/uhttpd restart
```

## 重要
该插件通过**注释锚点**安全重写局部块，请保留模板里的以下标记：

- Proxies 段：
  - `落地节点信息从下面开始添加`
  - `落地节点信息必须添加在这一行上面`
- Rules 段：
  - `落地节点对应的子网设备添加在下面`
  - `落地节点添加在上面`
- DNS 段：
  - `nameserver:` 列表
