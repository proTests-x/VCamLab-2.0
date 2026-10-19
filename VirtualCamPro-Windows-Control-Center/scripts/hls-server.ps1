[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [string]$BindAddress = "0.0.0.0",
    [int]$Port = 8888,
    [string]$PlaylistName = "live.m3u8"
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$root = [IO.Path]::GetFullPath($RootPath)
[IO.Directory]::CreateDirectory($root) | Out-Null

$bindIP = $null
if (-not [Net.IPAddress]::TryParse($BindAddress, [ref]$bindIP) -or
    $bindIP.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
    throw "BindAddress must be an IPv4 literal."
}
if ($Port -lt 1024 -or $Port -gt 65535) {
    throw "Port must be from 1024 through 65535."
}
if ([string]::IsNullOrWhiteSpace($PlaylistName) -or
    [IO.Path]::GetFileName($PlaylistName) -ne $PlaylistName -or
    $PlaylistName -notmatch '^[A-Za-z0-9._-]+[.]m3u8$') {
    throw "PlaylistName must be a simple .m3u8 file name."
}

# AVPlayer fetches a live playlist and media segments concurrently. The old
# single-client loop could remain blocked on one keep-alive/partial request and
# starve every other request, leaving AVPlayer permanently without a first
# frame. Keep protocol handling in a small C# worker so each accepted socket is
# served independently without requiring a PowerShell runspace per segment.
$serverSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace VirtualCamPro
{
    public static class HlsServer
    {
        private static readonly Regex SegmentPattern = new Regex(
            @"^segment_[0-9]{6,12}[.]ts$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private static readonly Regex RangePattern = new Regex(
            @"^bytes=(?<start>[0-9]*)-(?<end>[0-9]*)$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
        private static readonly SemaphoreSlim ClientSlots = new SemaphoreSlim(64, 64);
        private static string root;
        private static string rootPrefix;
        private static string playlistName;
        private static int loggedFirstPlaylist;
        private static int loggedFirstSegment;

        public static void Run(string rootPath, string bindAddress, int port, string playlist)
        {
            root = Path.GetFullPath(rootPath);
            rootPrefix = root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) +
                Path.DirectorySeparatorChar;
            playlistName = playlist;
            ThreadPool.SetMinThreads(16, 16);
            TcpListener listener = new TcpListener(IPAddress.Parse(bindAddress), port);
            listener.Server.NoDelay = true;
            listener.Start(64);
            try
            {
                while (true)
                {
                    TcpClient client = listener.AcceptTcpClient();
                    if (!ClientSlots.Wait(0))
                    {
                        client.Close();
                        continue;
                    }
                    ThreadPool.QueueUserWorkItem(delegate
                    {
                        try { HandleClient(client); }
                        finally
                        {
                            try { client.Close(); } catch { }
                            ClientSlots.Release();
                        }
                    });
                }
            }
            finally
            {
                listener.Stop();
            }
        }

        private static void HandleClient(TcpClient client)
        {
            client.NoDelay = true;
            client.ReceiveTimeout = 5000;
            client.SendTimeout = 15000;
            using (NetworkStream stream = client.GetStream())
            using (StreamReader reader = new StreamReader(stream, Encoding.ASCII, false, 8192, true))
            {
                try
                {
                    string requestLine = reader.ReadLine();
                    if (String.IsNullOrWhiteSpace(requestLine)) return;
                    if (requestLine.Length > 8192)
                    {
                        SendSimple(stream, 414, "URI Too Long", "URI Too Long", false);
                        return;
                    }
                    string[] parts = requestLine.Split(' ');
                    if (parts.Length < 2)
                    {
                        SendSimple(stream, 400, "Bad Request", "Bad Request", false);
                        return;
                    }
                    string method = parts[0].ToUpperInvariant();
                    string target = parts[1];
                    if (target.Length > 4096)
                    {
                        SendSimple(stream, 414, "URI Too Long", "URI Too Long", method == "HEAD");
                        return;
                    }
                    Dictionary<string, string> headers = ReadHeaders(reader);
                    if (method == "OPTIONS")
                    {
                        SendHeaders(stream, 204, "No Content", new Dictionary<string, string>
                        {
                            { "Content-Length", "0" },
                            { "Access-Control-Allow-Origin", "*" },
                            { "Access-Control-Allow-Methods", "GET, HEAD, OPTIONS" },
                            { "Access-Control-Allow-Headers", "Range" },
                            { "Connection", "close" }
                        });
                        return;
                    }
                    if (method != "GET" && method != "HEAD")
                    {
                        byte[] body = Encoding.UTF8.GetBytes("Method Not Allowed");
                        SendHeaders(stream, 405, "Method Not Allowed", new Dictionary<string, string>
                        {
                            { "Content-Type", "text/plain; charset=utf-8" },
                            { "Content-Length", body.Length.ToString() },
                            { "Allow", "GET, HEAD, OPTIONS" },
                            { "Cache-Control", "no-store" },
                            { "Access-Control-Allow-Origin", "*" },
                            { "X-Content-Type-Options", "nosniff" },
                            { "Connection", "close" }
                        });
                        stream.Write(body, 0, body.Length);
                        return;
                    }

                    int query = target.IndexOf('?');
                    string rawPath = query >= 0 ? target.Substring(0, query) : target;
                    string requestPath;
                    try { requestPath = Uri.UnescapeDataString(rawPath); }
                    catch { requestPath = String.Empty; }
                    if (requestPath == "/") requestPath = "/" + playlistName;
                    string relativePath = requestPath.TrimStart('/');
                    bool allowed = relativePath == playlistName || SegmentPattern.IsMatch(relativePath);
                    if (!allowed)
                    {
                        SendSimple(stream, 404, "Not Found", "Not Found", method == "HEAD");
                        return;
                    }

                    string fullPath = Path.GetFullPath(Path.Combine(root, relativePath));
                    if (!fullPath.StartsWith(rootPrefix, StringComparison.OrdinalIgnoreCase))
                    {
                        SendSimple(stream, 403, "Forbidden", "Forbidden", method == "HEAD");
                        return;
                    }
                    if (relativePath == playlistName && !File.Exists(fullPath))
                    {
                        for (int attempt = 0; attempt < 20 && !File.Exists(fullPath); attempt++)
                            Thread.Sleep(100);
                    }
                    if (!File.Exists(fullPath))
                    {
                        Console.Error.WriteLine("[HLS] 404 {0} requested by {1}",
                            relativePath, client.Client.RemoteEndPoint);
                        SendSimple(stream, 404, "Not Found", "Not Found", method == "HEAD");
                        return;
                    }

                    using (FileStream file = new FileStream(fullPath, FileMode.Open, FileAccess.Read,
                        FileShare.ReadWrite | FileShare.Delete))
                    {
                        long length = file.Length;
                        long start = 0;
                        long end = Math.Max(0, length - 1);
                        bool partial = false;
                        string rangeValue;
                        if (headers.TryGetValue("range", out rangeValue))
                        {
                            Match match = RangePattern.Match(rangeValue);
                            if (match.Success && length > 0)
                            {
                                string startText = match.Groups["start"].Value;
                                string endText = match.Groups["end"].Value;
                                if (startText.Length == 0 && endText.Length > 0)
                                {
                                    long suffixLength;
                                    if (Int64.TryParse(endText, out suffixLength) && suffixLength > 0)
                                    {
                                        start = Math.Max(0, length - suffixLength);
                                        end = length - 1;
                                    }
                                    else end = -1;
                                }
                                else
                                {
                                    long parsed;
                                    if (startText.Length > 0 && Int64.TryParse(startText, out parsed)) start = parsed;
                                    if (endText.Length > 0 && Int64.TryParse(endText, out parsed))
                                        end = Math.Min(parsed, length - 1);
                                }
                                if (start >= 0 && start < length && end >= start) partial = true;
                                else
                                {
                                    Console.Error.WriteLine("[HLS] 416 {0} range={1} length={2}",
                                        relativePath, rangeValue, length);
                                    SendHeaders(stream, 416, "Range Not Satisfiable", new Dictionary<string, string>
                                    {
                                        { "Content-Range", "bytes */" + length },
                                        { "Content-Length", "0" },
                                        { "Accept-Ranges", "bytes" },
                                        { "Access-Control-Allow-Origin", "*" },
                                        { "Cache-Control", "no-store" },
                                        { "Connection", "close" }
                                    });
                                    return;
                                }
                            }
                        }
                        long count = length == 0 ? 0 : end - start + 1;
                        bool isPlaylist = relativePath.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase);
                        if (isPlaylist && Interlocked.CompareExchange(ref loggedFirstPlaylist, 1, 0) == 0)
                            Console.WriteLine("[HLS] Serving the first playlist request to {0}",
                                client.Client.RemoteEndPoint);
                        if (!isPlaylist && Interlocked.CompareExchange(ref loggedFirstSegment, 1, 0) == 0)
                            Console.WriteLine("[HLS] Serving the first media segment ({0}) to {1}",
                                relativePath, client.Client.RemoteEndPoint);
                        Dictionary<string, string> responseHeaders = new Dictionary<string, string>
                        {
                            { "Content-Type", isPlaylist ? "application/vnd.apple.mpegurl" : "video/mp2t" },
                            { "Content-Length", count.ToString() },
                            { "Accept-Ranges", "bytes" },
                            { "Access-Control-Allow-Origin", "*" },
                            { "Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges" },
                            { "X-Content-Type-Options", "nosniff" },
                            { "Connection", "close" },
                            { "Cache-Control", isPlaylist ? "no-cache, no-store, must-revalidate" : "public, max-age=30" }
                        };
                        if (partial) responseHeaders["Content-Range"] =
                            "bytes " + start + "-" + end + "/" + length;
                        SendHeaders(stream, partial ? 206 : 200, partial ? "Partial Content" : "OK",
                            responseHeaders);
                        if (method == "HEAD" || count == 0) return;
                        file.Position = start;
                        byte[] buffer = new byte[65536];
                        long remaining = count;
                        while (remaining > 0)
                        {
                            int read = file.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                            if (read <= 0) break;
                            stream.Write(buffer, 0, read);
                            remaining -= read;
                        }
                    }
                }
                catch (Exception exception)
                {
                    Console.Error.WriteLine("[HLS] Client error from {0}: {1}",
                        client.Client.RemoteEndPoint, exception.Message);
                    try { SendSimple(stream, 500, "Internal Server Error", "Internal Server Error", false); }
                    catch { }
                }
            }
        }

        private static Dictionary<string, string> ReadHeaders(StreamReader reader)
        {
            Dictionary<string, string> headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            int lineCount = 0;
            int totalCharacters = 0;
            while (true)
            {
                string line = reader.ReadLine();
                if (line == null || line.Length == 0) break;
                lineCount++;
                totalCharacters += line.Length;
                if (lineCount > 100 || totalCharacters > 65536 || line.Length > 8192)
                    throw new InvalidDataException("HTTP request headers exceed the safety limit.");
                int separator = line.IndexOf(':');
                if (separator <= 0) continue;
                string name = line.Substring(0, separator).Trim().ToLowerInvariant();
                if (name.Length == 0 || name.Length > 256) continue;
                headers[name] = line.Substring(separator + 1).Trim();
            }
            return headers;
        }

        private static void SendSimple(Stream stream, int status, string reason, string body, bool head)
        {
            byte[] bodyBytes = Encoding.UTF8.GetBytes(body ?? String.Empty);
            SendHeaders(stream, status, reason, new Dictionary<string, string>
            {
                { "Content-Type", "text/plain; charset=utf-8" },
                { "Content-Length", bodyBytes.Length.ToString() },
                { "Cache-Control", "no-store" },
                { "Access-Control-Allow-Origin", "*" },
                { "X-Content-Type-Options", "nosniff" },
                { "Connection", "close" }
            });
            if (!head && bodyBytes.Length > 0) stream.Write(bodyBytes, 0, bodyBytes.Length);
        }

        private static void SendHeaders(Stream stream, int status, string reason,
            IDictionary<string, string> headers)
        {
            StringBuilder builder = new StringBuilder();
            builder.AppendFormat("HTTP/1.1 {0} {1}\r\n", status, reason);
            foreach (KeyValuePair<string, string> header in headers)
                builder.AppendFormat("{0}: {1}\r\n", header.Key, header.Value);
            builder.Append("\r\n");
            byte[] bytes = Encoding.ASCII.GetBytes(builder.ToString());
            stream.Write(bytes, 0, bytes.Length);
        }
    }
}
'@

Add-Type -TypeDefinition $serverSource -Language CSharp
[VirtualCamPro.HlsServer]::Run($root, $BindAddress, $Port, $PlaylistName)
