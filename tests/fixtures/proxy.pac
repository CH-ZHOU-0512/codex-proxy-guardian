function FindProxyForURL(url, host) {
    if (dnsDomainIs(host, ".openai.com") || host === "chatgpt.com") {
        return "PROXY 127.0.0.1:7890; SOCKS5 127.0.0.1:1080; DIRECT";
    }
    return "DIRECT";
}
