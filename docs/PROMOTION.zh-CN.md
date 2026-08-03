# Codex Proxy Guardian 发布与传播素材

这份文档提供可直接使用的首发文章、短文案和发布检查清单。发布时应以真实问题、真实能力和已知限制为主，不刷屏、不夸大，也不以奖励换取 Star。

## 推荐标题

主标题：

> Codex Windows 每次重连四五次才开始思考？我做了一个代理守护工具

备选标题：

> 开源：让 Codex Desktop 自动跟随 Clash/Mihomo 的有效代理端口

## 可直接发布的长文

我在 Windows 11 上使用 Codex 桌面版时，经常遇到一个很烦的问题：任务发出去后一直重连，常常要四五次才真正开始思考。浏览器和其他应用明明可以正常联网，Codex 却像是没有跟上当前代理。

后来排查发现，很多代理软件会在本机提供一个 HTTP 或混合端口。代理软件重启、切换配置或更新后，端口可能发生变化；已经运行的 Codex 仍然保留旧代理地址，或者启动时根本没有得到正确代理参数。手动解决需要查端口、关 Codex、设置环境变量和启动参数，再重新打开，端口变化后还得重复一遍。

所以我做了 **Codex Proxy Guardian**：

- 自动检查 Windows 当前代理、代理环境变量和 Clash/Mihomo、v2rayN/Xray、sing-box 等常见程序的本地监听端口；
- 不只看端口是否打开，还会通过该代理访问多个 OpenAI/ChatGPT HTTPS 测试目标；
- 代理地址稳定变化后，为 Codex 配置当前代理并进行受控重启；
- 带防抖、重启冷却、频率限制和熔断，避免守护脚本反过来造成 Codex 重启循环；
- 当前用户静默自启，不需要管理员权限；
- 不修改 Windows 系统代理、WinHTTP、DNS、路由或永久环境变量；
- 状态中可以看到 `ValidatedProxy`、`LaunchConfigured` 和 `TrafficObserved` 三个层级的生效证据。

一句话说：**如果 Codex 经常要重连四五次才开始思考，而原因是代理没有正确跟上，这个工具就是用来解决它的。**

安装方式：从 Release 下载 ZIP，解压后在普通权限 PowerShell 中执行：

```powershell
Unblock-File .\Install.ps1
.\Install.ps1
```

项目默认使用 `Safe` 模式。它本身不是代理软件，也不提供代理服务或节点；使用前电脑上需要已经存在一个可用的 HTTP/HTTPS 代理。PAC/WPAD、纯 SOCKS、只有 TUN 而没有 HTTP/混合端口的配置目前不会自动支持。

项目地址：<https://github.com/CH-ZHOU-0512/codex-proxy-guardian>

目前仍是 Alpha 预发布版本，我更希望先收集不同 Windows、Codex 和代理软件组合下的真实结果。如果它确实解决了你的问题，欢迎点一个 Star，让更多遇到同样问题的人看到；如果没有解决，也欢迎提交经过人工检查的脱敏 Doctor 报告。

## 短文案

### 论坛摘要

Codex Windows 经常重连四五次才开始思考，可能不是代理本身不可用，而是 Codex 没有跟上代理端口变化。我开源了 Codex Proxy Guardian：自动发现并实际验证 HTTP/HTTPS 代理，只在稳定变化后受控重启 Codex，带防抖、冷却和熔断，不修改系统网络配置。当前为 Alpha，欢迎实测反馈。

<https://github.com/CH-ZHOU-0512/codex-proxy-guardian>

### 一句话分享

让 Codex 不再因为代理端口没跟上而反复重连：自动发现、实际验证、安全切换，不修改系统代理。

<https://github.com/CH-ZHOU-0512/codex-proxy-guardian>

## 发布检查清单

- 使用 `assets/social-preview.png` 作为首图；
- 正文中放一张 `assets/how-it-works.png`；
- 如有真实录屏，放在问题描述之后，不要用模拟结果冒充实测；
- 明确这是非官方 Alpha 项目，并列出暂不支持范围；
- 不公开代理地址、IP、用户名、令牌或未经脱敏的日志；
- 不在无关主题下刷屏，不购买、交换或奖励 Star；
- 发布后回答真实问题，并把重复出现的问题补进 README；
- 24 小时后在 GitHub `Insights → Traffic` 查看来源、访问和热门页面；
- 根据真实下载、兼容性报告和问题解决率判断传播效果，不只看 Star 数量。
