[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ListenHost,
    [Parameter(Mandatory = $true)][int]$ListenPort,
    [Parameter(Mandatory = $true)][string]$TargetHost,
    [Parameter(Mandatory = $true)][int]$TargetPort,
    [Parameter(Mandatory = $true)][string]$InstanceToken,
    [Parameter(Mandatory = $true)][string]$ReadyPath,
    [Parameter(Mandatory = $true)][string]$StopPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not ('CodexProxyGuardian.TcpRelay' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;

namespace CodexProxyGuardian {
    public static class TcpRelay {
        private static void Pump(NetworkStream source, NetworkStream target) {
            try {
                source.CopyTo(target, 64 * 1024);
            }
            catch (IOException) { }
            catch (SocketException) { }
            catch (ObjectDisposedException) { }
        }

        private static void Handle(TcpClient client, string targetHost, int targetPort) {
            TcpClient upstream = null;
            try {
                upstream = new TcpClient();
                upstream.NoDelay = true;
                upstream.Connect(targetHost, targetPort);
                client.NoDelay = true;
                NetworkStream downstream = client.GetStream();
                NetworkStream upstreamStream = upstream.GetStream();
                Task downToUp = Task.Run(() => Pump(downstream, upstreamStream));
                Task upToDown = Task.Run(() => Pump(upstreamStream, downstream));
                Task.WaitAny(downToUp, upToDown);
            }
            catch (SocketException) { }
            catch (IOException) { }
            catch (ObjectDisposedException) { }
            finally {
                try { if (upstream != null) upstream.Close(); } catch { }
                try { if (client != null) client.Close(); } catch { }
            }
        }

        public static int Run(string listenHost, int listenPort, string targetHost, int targetPort, string readyPath, string stopPath) {
            TcpListener listener = null;
            try {
                IPAddress listenAddress;
                if (!IPAddress.TryParse(listenHost, out listenAddress)) return 21;
                listener = new TcpListener(listenAddress, listenPort);
                listener.Start(64);
                File.WriteAllText(readyPath, Process.GetCurrentProcess().Id.ToString());
                while (!File.Exists(stopPath)) {
                    if (listener.Pending()) {
                        TcpClient client = listener.AcceptTcpClient();
                        Task.Run(() => Handle(client, targetHost, targetPort));
                    }
                    Thread.Sleep(100);
                }
                return 0;
            }
            catch (SocketException) { return 22; }
            catch (UnauthorizedAccessException) { return 23; }
            finally {
                try { if (listener != null) listener.Stop(); } catch { }
                try { if (File.Exists(readyPath)) File.Delete(readyPath); } catch { }
            }
        }
    }
}
'@
}

$readyDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($ReadyPath))
if (-not (Test-Path -LiteralPath $readyDirectory)) {
    New-Item -ItemType Directory -Path $readyDirectory -Force | Out-Null
}
Remove-Item -LiteralPath $ReadyPath -Force -ErrorAction SilentlyContinue
$exitCode = [CodexProxyGuardian.TcpRelay]::Run($ListenHost, $ListenPort, $TargetHost, $TargetPort, $ReadyPath, $StopPath)
exit $exitCode
