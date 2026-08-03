# 安全策略 / Security policy

## 支持版本

安全修复面向最新带标签的发布版本。预发布版本不提供长期支持保证。

## 报告安全漏洞

如果漏洞可能泄露凭据、执行代码、删除无关数据或绕过企业策略，请勿提交公开 Issue。请使用仓库的 Private Security Advisory，并提供：

- 受影响版本与 Windows 版本；
- 最小复现步骤；
- 预期行为与实际行为；
- 机密信息或无关文件/任务是否可能受到影响；
- 已知的缓解建议。

请勿提供真实代理凭据、访问令牌、用户名、公网 IP 或未经脱敏的日志。维护者应在七天内确认信息完整的报告，并在修复或缓解措施可用后协调披露。

## 设计承诺

本项目不请求管理员权限，不修改 Windows/WinHTTP 代理，不持久化代理环境变量，不抓包，也不收集遥测。流量证据只使用本地 TCP 连接元数据，不会发送到远程服务。Release 压缩包应能使用 `tools\Package-Release.ps1` 从对应标签源码重新构建；安装前请校验发布的 SHA-256。

## English summary

Security fixes target the latest tagged release; pre-releases have no long-term support guarantee. Do not open a public issue for vulnerabilities involving credentials, code execution, unrelated data deletion, or enterprise-policy bypass. Use GitHub Private Security Advisories and never include real credentials, tokens, usernames, public IPs, or unredacted logs. The project does not request elevation, mutate network settings, capture packets, or collect telemetry.
