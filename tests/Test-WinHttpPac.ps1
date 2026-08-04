[CmdletBinding()]
param([int]$Port = 18765)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$watcherPath = Join-Path $repoRoot 'src\Watch-CodexProxy.ps1'
$pacContent = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'fixtures\proxy.pac')

if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
    throw "Port $Port is already in use."
}

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public sealed class CpgPacTestServer : IDisposable {
    private readonly TcpListener listener;
    private readonly byte[] body;
    private readonly Thread thread;
    private volatile bool stopping;

    public CpgPacTestServer(int port, string content) {
        listener = new TcpListener(IPAddress.Loopback, port);
        body = Encoding.UTF8.GetBytes(content);
        thread = new Thread(Run) { IsBackground = true };
    }

    public void Start() {
        listener.Start();
        thread.Start();
    }

    private void Run() {
        while (!stopping) {
            TcpClient client = null;
            try {
                client = listener.AcceptTcpClient();
                NetworkStream stream = client.GetStream();
                int state = 0;
                while (state < 4) {
                    int value = stream.ReadByte();
                    if (value < 0) break;
                    byte expected = new byte[] { 13, 10, 13, 10 }[state];
                    state = value == expected ? state + 1 : (value == 13 ? 1 : 0);
                }
                byte[] headers = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/x-ns-proxy-autoconfig\r\nContent-Length: " +
                    body.Length + "\r\nConnection: close\r\n\r\n");
                stream.Write(headers, 0, headers.Length);
                stream.Write(body, 0, body.Length);
                stream.Flush();
            }
            catch (SocketException) { if (!stopping) throw; }
            catch (ObjectDisposedException) { if (!stopping) throw; }
            finally { if (client != null) client.Close(); }
        }
    }

    public void Dispose() {
        stopping = true;
        listener.Stop();
        if (thread.IsAlive) thread.Join(2000);
    }
}
'@

$server = New-Object -TypeName CpgPacTestServer -ArgumentList $Port, $pacContent
$server.Start()

try {
    $content = Get-Content -Raw -Encoding UTF8 -LiteralPath $watcherPath
    $match = [regex]::Match($content, "(?s)Add-Type -TypeDefinition @'\r?\n(.*?)\r?\n'@")
    if (-not $match.Success) { throw 'WinHTTP helper source was not found.' }
    Add-Type -TypeDefinition $match.Groups[1].Value

    $pacUrl = "http://127.0.0.1:$Port/proxy.pac"
    $resolved = [CodexProxyGuardian.WinHttpAutoProxy]::Resolve('https://chatgpt.com/', $pacUrl, $false, 3000)
    if ($resolved -notmatch '127\.0\.0\.1:7890') {
        throw "Unexpected WinHTTP PAC result: $resolved"
    }
    Write-Output "WinHTTP PAC resolved: $resolved"
}
finally {
    $server.Dispose()
}
