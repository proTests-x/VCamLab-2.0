@rem VirtualCamPro Windows launcher configuration.
@rem Edit only the values after the equals signs. Empty paths are auto-detected.

@rem Optional exact executable paths.
set "VCAM_FFMPEG_PATH="
set "VCAM_OBS_PATH="

@rem Optional OBS scene. Leave blank to keep the saved scene.
set "VCAM_OBS_SCENE="

@rem auto reads the current saved OBS profile on launcher start and OBS reconnect.
@rem Explicit alternatives: landscape or portrait; 720p, 1080p, 1440p, or 2160p.
set "VCAM_ORIENTATION=landscape"
set "VCAM_RESOLUTION=720p"
@rem Accepts 1-240, including 23.976, 59.94, 120, 240, or rational expressions.
@rem OBS must publish the same rate; restart Virtual Camera after changing OBS Video settings.
set "VCAM_FPS=30"

@rem fill crops the edges to remove bars; fit preserves the whole source; stretch distorts it.
set "VCAM_SCALE_MODE=fill"

@rem Streaming transport: mjpeg for lowest latency, hls for H.264/HLS delivery.
@rem MJPEG URL: http://PC_IP:PORT/live.mjpg
@rem HLS URL:    http://PC_IP:PORT/live.m3u8
set "VCAM_TRANSPORT=mjpeg"

@rem FFmpeg MJPEG quality from 1 through 31. Lower is clearer and uses more bandwidth.
@rem Quality 1 is the maximum encoder quality; ignored when VCAM_TRANSPORT=hls.
set "VCAM_QUALITY=5"

@rem HLS/H.264 settings. These are ignored in MJPEG mode.
@rem 250 ms segments with an Apple-compatible six-segment live window.
set "VCAM_HLS_SEGMENT_SECONDS=0.25"
set "VCAM_HLS_LIST_SIZE=6"
@rem kbps; tuned for high-quality 1080x1920 around 30-60 FPS on a LAN.
set "VCAM_HLS_VIDEO_BITRATE_KBPS=12000"
set "VCAM_HLS_MAXRATE_KBPS=16000"
set "VCAM_HLS_BUFSIZE_KBPS=12000"
@rem x264 presets: ultrafast, superfast, veryfast, faster, fast, medium.
set "VCAM_HLS_PRESET=ultrafast"

@rem HTTP listener. 0.0.0.0 exposes it on all IPv4 network adapters.
set "VCAM_BIND_ADDRESS=0.0.0.0"
set "VCAM_PORT=8888"

@rem Startup and recovery behavior.
set "VCAM_OBS_WAIT_SECONDS=15"
set "VCAM_RESTART_ON_DISCONNECT=true"

@rem Low-latency bounded buffers. Congestion drops stale frames instead of
@rem accumulating seconds of video; FPS, resolution and quality stay unchanged.
set "VCAM_RT_BUFFER_MB=64"
set "VCAM_THREAD_QUEUE_SIZE=4"

@rem Parallel JPEG encoding plus bounded encoded/TCP buffers are used only by MJPEG.
set "VCAM_ENCODER_THREADS=4"
set "VCAM_OUTPUT_QUEUE_SIZE=3"
set "VCAM_TCP_SEND_BUFFER_MB=1"

@rem error keeps the GUI concise; use warning or info for deeper FFmpeg diagnostics.
set "VCAM_FFMPEG_LOG_LEVEL=error"

@rem Refuse to silently upscale a stale or low-resolution OBS Virtual Camera mode.
set "VCAM_REQUIRE_OBS_MODE_MATCH=false"

@rem When OBS is already running, use its password-protected local WebSocket API to
@rem start or safely refresh only Virtual Camera. OBS itself is never force-closed.
set "VCAM_AUTO_REFRESH_OBS_VIRTUAL_CAMERA=true"

@rem Change only if FFmpeg lists the OBS virtual camera under another exact name.
set "VCAM_DEVICE_NAME=OBS Virtual Camera"
