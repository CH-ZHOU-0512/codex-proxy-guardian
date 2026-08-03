using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace CodexProxyGuardian.Setup
{
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            if (args.Length == 1 && string.Equals(args[0], "--verify", StringComparison.OrdinalIgnoreCase))
            {
                return Bootstrapper.VerifyPayload();
            }

            bool ownsMutex;
            using (var mutex = new Mutex(true, @"Local\CodexProxyGuardian.Setup", out ownsMutex))
            {
                if (!ownsMutex)
                {
                    MessageBox.Show(
                        "Codex Proxy Guardian \u5b89\u88c5\u7a0b\u5e8f\u5df2\u7ecf\u5728\u8fd0\u884c\u3002",
                        "Codex Proxy Guardian",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information);
                    return 1;
                }

                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                using (var form = new SetupForm())
                {
                    Application.Run(form);
                    return form.ExitCode;
                }
            }
        }
    }

    internal sealed class SetupForm : Form
    {
        private readonly Button installButton;
        private readonly Button cancelButton;
        private readonly Label statusLabel;
        private readonly ProgressBar progressBar;
        private readonly BackgroundWorker worker;
        private bool completed;

        internal int ExitCode { get; private set; }

        internal SetupForm()
        {
            ExitCode = 1;
            Text = "Codex Proxy Guardian Setup";
            ClientSize = new Size(640, 430);
            MinimumSize = new Size(640, 430);
            MaximumSize = new Size(640, 430);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            BackColor = Color.FromArgb(243, 241, 232);
            ForeColor = Color.FromArgb(17, 21, 16);
            Font = new Font("Segoe UI", 10F, FontStyle.Regular, GraphicsUnit.Point);
            AutoScaleMode = AutoScaleMode.Dpi;

            var mark = new Label
            {
                Text = "C",
                TextAlign = ContentAlignment.MiddleCenter,
                BackColor = Color.FromArgb(17, 21, 16),
                ForeColor = Color.FromArgb(243, 241, 232),
                Font = new Font("Segoe UI", 16F, FontStyle.Bold, GraphicsUnit.Point),
                Location = new Point(42, 36),
                Size = new Size(48, 48)
            };
            Controls.Add(mark);

            var product = new Label
            {
                Text = "Codex Proxy Guardian",
                Font = new Font("Segoe UI", 16F, FontStyle.Bold, GraphicsUnit.Point),
                AutoSize = true,
                Location = new Point(104, 45)
            };
            Controls.Add(product);

            var version = FileVersionInfo.GetVersionInfo(Application.ExecutablePath).ProductVersion;
            var versionLabel = new Label
            {
                Text = "v" + version,
                ForeColor = Color.FromArgb(98, 104, 95),
                AutoSize = true,
                Location = new Point(538, 51)
            };
            Controls.Add(versionLabel);

            var divider = new Panel
            {
                BackColor = Color.FromArgb(205, 208, 198),
                Location = new Point(42, 103),
                Size = new Size(556, 1)
            };
            Controls.Add(divider);

            var title = new Label
            {
                Text = "\u8ba9 Codex \u81ea\u52a8\u8ddf\u968f\u5f53\u524d\u6709\u6548\u4ee3\u7406",
                Font = new Font("Microsoft YaHei UI", 19F, FontStyle.Bold, GraphicsUnit.Point),
                AutoSize = false,
                Location = new Point(42, 132),
                Size = new Size(556, 42)
            };
            Controls.Add(title);

            var description = new Label
            {
                Text = "\u5b89\u88c5\u6216\u5347\u7ea7\u5230\u5f53\u524d\u7528\u6237\u3002\u5b8c\u6210\u540e Guardian \u4f1a\u7acb\u5373\u542f\u52a8\uff0c\u5e76\u5728\u4ee5\u540e\u767b\u5f55 Windows \u65f6\u9759\u9ed8\u8fd0\u884c\u3002",
                ForeColor = Color.FromArgb(98, 104, 95),
                AutoSize = false,
                Location = new Point(44, 184),
                Size = new Size(548, 54)
            };
            Controls.Add(description);

            var safetyPanel = new Panel
            {
                BackColor = Color.FromArgb(220, 232, 223),
                Location = new Point(42, 250),
                Size = new Size(556, 56)
            };
            var safety = new Label
            {
                Text = "\u9ed8\u8ba4\u81ea\u52a8\u6a21\u5f0f   \u00b7   \u4e0d\u4fee\u6539\u7cfb\u7edf\u4ee3\u7406   \u00b7   \u65e0\u9700\u7ba1\u7406\u5458\u6743\u9650",
                ForeColor = Color.FromArgb(34, 77, 59),
                Font = new Font("Microsoft YaHei UI", 9.5F, FontStyle.Bold, GraphicsUnit.Point),
                TextAlign = ContentAlignment.MiddleCenter,
                Dock = DockStyle.Fill
            };
            safetyPanel.Controls.Add(safety);
            Controls.Add(safetyPanel);

            statusLabel = new Label
            {
                Text = "\u51c6\u5907\u5b89\u88c5",
                ForeColor = Color.FromArgb(98, 104, 95),
                AutoSize = false,
                Location = new Point(44, 325),
                Size = new Size(554, 22)
            };
            Controls.Add(statusLabel);

            progressBar = new ProgressBar
            {
                Style = ProgressBarStyle.Marquee,
                MarqueeAnimationSpeed = 28,
                Location = new Point(44, 352),
                Size = new Size(350, 6),
                Visible = false
            };
            Controls.Add(progressBar);

            cancelButton = new Button
            {
                Text = "\u53d6\u6d88",
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(243, 241, 232),
                ForeColor = Color.FromArgb(17, 21, 16),
                Location = new Point(406, 344),
                Size = new Size(88, 42),
                TabIndex = 1
            };
            cancelButton.FlatAppearance.BorderColor = Color.FromArgb(205, 208, 198);
            cancelButton.Click += delegate { Close(); };
            Controls.Add(cancelButton);

            installButton = new Button
            {
                Text = "\u7acb\u5373\u5b89\u88c5",
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(47, 107, 80),
                ForeColor = Color.White,
                Font = new Font("Microsoft YaHei UI", 10F, FontStyle.Bold, GraphicsUnit.Point),
                Location = new Point(504, 344),
                Size = new Size(94, 42),
                TabIndex = 0
            };
            installButton.FlatAppearance.BorderSize = 0;
            installButton.Click += InstallButtonClick;
            Controls.Add(installButton);
            AcceptButton = installButton;
            CancelButton = cancelButton;

            var projectLink = new LinkLabel
            {
                Text = "github.com/CH-ZHOU-0512/codex-proxy-guardian",
                LinkColor = Color.FromArgb(47, 107, 80),
                ActiveLinkColor = Color.FromArgb(34, 77, 59),
                AutoSize = true,
                Location = new Point(42, 399)
            };
            projectLink.LinkClicked += delegate
            {
                try { Process.Start("https://github.com/CH-ZHOU-0512/codex-proxy-guardian"); }
                catch { }
            };
            Controls.Add(projectLink);

            worker = new BackgroundWorker();
            worker.DoWork += delegate(object sender, DoWorkEventArgs eventArgs)
            {
                eventArgs.Result = Bootstrapper.Install();
            };
            worker.RunWorkerCompleted += WorkerCompleted;
            FormClosing += SetupFormClosing;
        }

        private void InstallButtonClick(object sender, EventArgs eventArgs)
        {
            if (completed)
            {
                Close();
                return;
            }

            installButton.Enabled = false;
            cancelButton.Enabled = false;
            ControlBox = false;
            progressBar.Visible = true;
            statusLabel.Text = "\u6b63\u5728\u9a8c\u8bc1\u5b89\u88c5\u5305\u5e76\u5b89\u88c5\uff0c\u8bf7\u7a0d\u5019\u2026";
            worker.RunWorkerAsync();
        }

        private void WorkerCompleted(object sender, RunWorkerCompletedEventArgs eventArgs)
        {
            progressBar.Visible = false;
            ControlBox = true;
            completed = true;
            cancelButton.Visible = false;
            installButton.Enabled = true;
            installButton.Text = "\u5173\u95ed";

            var result = eventArgs.Result as InstallResult;
            if (eventArgs.Error != null)
            {
                result = InstallResult.Failure(eventArgs.Error.Message, string.Empty);
            }
            if (result == null)
            {
                result = InstallResult.Failure("Unknown installer result.", string.Empty);
            }

            ExitCode = result.Success ? 0 : 2;
            statusLabel.ForeColor = result.Success ? Color.FromArgb(47, 107, 80) : Color.FromArgb(160, 50, 45);
            statusLabel.Text = result.UserMessage;
            if (!result.Success && !string.IsNullOrWhiteSpace(result.LogPath))
            {
                statusLabel.Text += "  Log: " + result.LogPath;
            }
        }

        private void SetupFormClosing(object sender, FormClosingEventArgs eventArgs)
        {
            if (worker.IsBusy)
            {
                eventArgs.Cancel = true;
            }
        }
    }

    internal sealed class InstallResult
    {
        internal bool Success { get; private set; }
        internal string UserMessage { get; private set; }
        internal string LogPath { get; private set; }

        internal static InstallResult Succeeded()
        {
            return new InstallResult
            {
                Success = true,
                UserMessage = "\u5b89\u88c5\u5b8c\u6210\u3002Guardian \u5df2\u5728\u540e\u53f0\u8fd0\u884c\uff0c\u4ee5\u540e\u76f4\u63a5\u6253\u5f00 Codex \u5373\u53ef\u3002",
                LogPath = string.Empty
            };
        }

        internal static InstallResult Failure(string message, string logPath)
        {
            return new InstallResult
            {
                Success = false,
                UserMessage = "\u5b89\u88c5\u5931\u8d25\uff0c\u539f\u6709\u7f51\u7edc\u914d\u7f6e\u672a\u4fee\u6539\u3002" + (string.IsNullOrWhiteSpace(message) ? string.Empty : " " + message),
                LogPath = logPath ?? string.Empty
            };
        }
    }

    internal static class Bootstrapper
    {
        private const string PayloadResource = "CodexProxyGuardian.Payload.zip";
        private const int MaximumEntries = 4096;
        private const long MaximumExpandedBytes = 128L * 1024L * 1024L;
        private const long MaximumEntryBytes = 32L * 1024L * 1024L;

        internal static int VerifyPayload()
        {
            string temporaryRoot = null;
            try
            {
                string projectRoot;
                temporaryRoot = ExtractPayload(out projectRoot);
                ValidatePayload(projectRoot);
                return 0;
            }
            catch
            {
                return 3;
            }
            finally
            {
                SafeDeleteTemporaryRoot(temporaryRoot);
            }
        }

        internal static InstallResult Install()
        {
            string temporaryRoot = null;
            var output = new StringBuilder();
            try
            {
                string projectRoot;
                temporaryRoot = ExtractPayload(out projectRoot);
                ValidatePayload(projectRoot);

                string powerShell = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    @"WindowsPowerShell\v1.0\powershell.exe");
                if (!File.Exists(powerShell))
                {
                    throw new FileNotFoundException("Windows PowerShell 5.1 was not found.", powerShell);
                }

                var startInfo = new ProcessStartInfo
                {
                    FileName = powerShell,
                    Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" +
                                Path.Combine(projectRoot, "Install.ps1") + "\"",
                    WorkingDirectory = projectRoot,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    RedirectStandardOutput = true,
                    RedirectStandardError = true
                };

                using (var process = new Process { StartInfo = startInfo })
                {
                    process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                    {
                        if (eventArgs.Data != null) output.AppendLine(eventArgs.Data);
                    };
                    process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
                    {
                        if (eventArgs.Data != null) output.AppendLine(eventArgs.Data);
                    };
                    if (!process.Start()) throw new InvalidOperationException("Could not start Windows PowerShell.");
                    process.BeginOutputReadLine();
                    process.BeginErrorReadLine();
                    if (!process.WaitForExit(10 * 60 * 1000))
                    {
                        try { process.Kill(); }
                        catch { }
                        throw new TimeoutException("Install.ps1 did not finish within ten minutes.");
                    }
                    process.WaitForExit();
                    if (process.ExitCode != 0)
                    {
                        throw new InvalidOperationException("Install.ps1 exited with code " + process.ExitCode + ".");
                    }
                }

                return InstallResult.Succeeded();
            }
            catch (Exception exception)
            {
                output.AppendLine(exception.ToString());
                string logPath = WriteFailureLog(output.ToString());
                return InstallResult.Failure(exception.Message, logPath);
            }
            finally
            {
                SafeDeleteTemporaryRoot(temporaryRoot);
            }
        }

        private static string ExtractPayload(out string projectRoot)
        {
            var temporaryRoot = Path.Combine(
                Path.GetTempPath(),
                "CodexProxyGuardian-Setup-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(temporaryRoot);
            var rootPrefix = Path.GetFullPath(temporaryRoot).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;

            Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(PayloadResource);
            if (resource == null)
            {
                throw new InvalidDataException("The embedded installer payload is missing.");
            }

            using (resource)
            using (var archive = new ZipArchive(resource, ZipArchiveMode.Read, false))
            {
                if (archive.Entries.Count == 0 || archive.Entries.Count > MaximumEntries)
                {
                    throw new InvalidDataException("The embedded payload has an invalid entry count.");
                }

                long totalExpanded = 0;
                foreach (var entry in archive.Entries)
                {
                    if (entry.Length < 0 || entry.Length > MaximumEntryBytes)
                    {
                        throw new InvalidDataException("An embedded payload entry exceeds the size limit.");
                    }
                    if (entry.FullName.IndexOf(':') >= 0)
                    {
                        throw new InvalidDataException("The embedded payload contains an invalid path.");
                    }
                    totalExpanded += entry.Length;
                    if (totalExpanded > MaximumExpandedBytes)
                    {
                        throw new InvalidDataException("The embedded payload exceeds the expansion limit.");
                    }

                    var targetPath = Path.GetFullPath(Path.Combine(temporaryRoot, entry.FullName));
                    if (!targetPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new InvalidDataException("The embedded payload contains an unsafe path.");
                    }

                    if (string.IsNullOrEmpty(entry.Name))
                    {
                        Directory.CreateDirectory(targetPath);
                        continue;
                    }

                    var parent = Path.GetDirectoryName(targetPath);
                    if (string.IsNullOrEmpty(parent)) throw new InvalidDataException("The embedded payload path is invalid.");
                    Directory.CreateDirectory(parent);
                    using (var input = entry.Open())
                    using (var output = new FileStream(targetPath, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        var buffer = new byte[81920];
                        long written = 0;
                        int read;
                        while ((read = input.Read(buffer, 0, buffer.Length)) > 0)
                        {
                            written += read;
                            if (written > MaximumEntryBytes)
                            {
                                throw new InvalidDataException("An embedded payload entry expanded past the size limit.");
                            }
                            output.Write(buffer, 0, read);
                        }
                    }
                }
            }

            projectRoot = Path.Combine(temporaryRoot, "CodexProxyGuardian");
            return temporaryRoot;
        }

        private static void ValidatePayload(string projectRoot)
        {
            var required = new[]
            {
                "Install.ps1",
                "VERSION",
                @"config\default-config.json",
                @"src\CodexProxyGuardian.Core.psm1",
                @"src\Watch-CodexProxy.ps1"
            };
            foreach (var relativePath in required)
            {
                if (!File.Exists(Path.Combine(projectRoot, relativePath)))
                {
                    throw new InvalidDataException("The embedded payload is incomplete: " + relativePath);
                }
            }

            var version = File.ReadAllText(Path.Combine(projectRoot, "VERSION")).Trim();
            if (string.IsNullOrWhiteSpace(version))
            {
                throw new InvalidDataException("The embedded payload VERSION is empty.");
            }
            var versionAttribute = (AssemblyInformationalVersionAttribute)Attribute.GetCustomAttribute(
                Assembly.GetExecutingAssembly(),
                typeof(AssemblyInformationalVersionAttribute));
            if (versionAttribute == null || !string.Equals(version, versionAttribute.InformationalVersion, StringComparison.Ordinal))
            {
                throw new InvalidDataException("The embedded payload VERSION does not match the installer.");
            }
        }

        private static string WriteFailureLog(string text)
        {
            try
            {
                var path = Path.Combine(Path.GetTempPath(), "CodexProxyGuardian-Setup.log");
                File.AppendAllText(
                    path,
                    DateTime.UtcNow.ToString("o") + Environment.NewLine + text + Environment.NewLine,
                    Encoding.UTF8);
                return path;
            }
            catch
            {
                return string.Empty;
            }
        }

        private static void SafeDeleteTemporaryRoot(string temporaryRoot)
        {
            if (string.IsNullOrWhiteSpace(temporaryRoot) || !Directory.Exists(temporaryRoot)) return;
            try
            {
                var tempBase = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
                var resolved = Path.GetFullPath(temporaryRoot).TrimEnd(Path.DirectorySeparatorChar);
                if (resolved.StartsWith(tempBase + "CodexProxyGuardian-Setup-", StringComparison.OrdinalIgnoreCase))
                {
                    Directory.Delete(resolved, true);
                }
            }
            catch
            {
            }
        }
    }
}
