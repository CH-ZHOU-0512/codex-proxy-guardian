# 参与贡献 / Contributing

欢迎提交中文或英文 Bug 报告，以及范围明确的 Pull Request。

提交代码前请确认：

1. 说明 Windows 版本、Codex 分发来源、代理模式和预期行为，但不要包含私人网络信息。
2. 保持“不修改网络配置”的保证：不得写入系统代理、WinHTTP、DNS、路由或永久代理环境变量。
3. 保持 `Safe` 为公开安装的默认模式。
4. 条件允许时同时运行 Windows PowerShell 5.1 与 PowerShell 7 测试：

   ```powershell
   powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
   pwsh -NoProfile -File .\tests\Run-Tests.ps1
   ```

5. 用户可见行为发生变化时，更新兼容性矩阵和更新日志。

新的代理适配必须证明其 HTTP/HTTPS 语义、避免凭据泄露，并定义确定性的优先级。任何可能关闭或重启 Codex 的改动都必须包含防抖、冷却以及 PID/进程交接测试。

提交贡献即表示你同意以 MIT 许可证发布该贡献。

## English summary

Chinese or English bug reports and narrowly scoped pull requests are welcome. Preserve the no-network-mutation guarantee, keep Safe mode as the public default, prevent credentials from entering logs or command lines, and add debounce/cooldown plus PID-handoff coverage to restart-related behavior. Run the Windows PowerShell 5.1 and PowerShell 7 tests when available. Contributions are licensed under the MIT License.
