use std::{
    collections::HashMap,
    ffi::{CStr, CString, c_char, c_void},
    net::IpAddr,
    os::fd::IntoRawFd,
    sync::{
        Mutex, OnceLock,
        atomic::{AtomicU64, Ordering},
    },
    time::Duration,
};

use base64::{Engine, prelude::BASE64_STANDARD};
use futures_util::FutureExt;
use idevice::{
    RsdService as _,
    remote_pairing::{
        PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient, RpPairingFile,
        RpPairingSocket, connect_tls_psk_tunnel_native,
    },
    services::{lockdown::LockdownClient, rsd::RsdHandshake},
    tcp::adapter::Adapter,
};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt},
    net::{TcpListener, TcpStream, UnixStream},
    runtime::Runtime,
    sync::oneshot,
};

type EventCallback = extern "C" fn(*const c_char, *mut c_void);

#[derive(Clone, Copy)]
struct Events {
    callback: EventCallback,
    context: usize,
}

impl Events {
    fn send(self, value: Value) {
        if let Ok(text) = CString::new(value.to_string()) {
            (self.callback)(text.as_ptr(), self.context as *mut c_void);
        }
    }
}

fn runtime() -> &'static Runtime {
    static RT: OnceLock<Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_stack_size(4 * 1024 * 1024)
            .enable_all()
            .build()
            .expect("failed to build tokio runtime")
    })
}

fn pairing_sessions() -> &'static Mutex<HashMap<u64, oneshot::Sender<()>>> {
    static SESSIONS: OnceLock<Mutex<HashMap<u64, oneshot::Sender<()>>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn active_tunnels() -> &'static Mutex<HashMap<u64, oneshot::Sender<()>>> {
    static TUNNELS: OnceLock<Mutex<HashMap<u64, oneshot::Sender<()>>>> = OnceLock::new();
    TUNNELS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn to_c_json(value: Value) -> *mut c_char {
    CString::new(value.to_string())
        .unwrap_or_else(|_| CString::new("{\"ok\":false,\"error\":\"serialization failed\"}").unwrap())
        .into_raw()
}

fn parse_rp_record(record: *const u8, length: usize) -> Result<RpPairingFile, String> {
    if record.is_null() || length == 0 || length > 2_000_000 {
        return Err("配对数据为空或体积异常".into());
    }
    let bytes = unsafe { std::slice::from_raw_parts(record, length) };
    let parsed = RpPairingFile::from_bytes(bytes).map_err(|_| "配对身份格式无效".to_string())?;
    if parsed.e_private_key.verifying_key() != parsed.e_public_key {
        return Err("配对身份公私钥不匹配".into());
    }
    Ok(parsed)
}

async fn establish_rsd(
    mut record: RpPairingFile,
    host_ip: IpAddr,
    port: u16,
) -> Result<
    (
        RemotePairingClient<RpPairingSocket<TcpStream>>,
        idevice::tcp::handle::AdapterHandle,
        RsdHandshake,
    ),
    String,
> {
    let stream = TcpStream::connect((host_ip, port))
        .await
        .map_err(|e| format!("无法连接回环地址 {host_ip}:{port}（请确认外部代理已开启 10.7.0.1 回环）：{e}"))?;
    let _ = stream.set_nodelay(true);

    let mut client = RemotePairingClient::new(RpPairingSocket::new(stream), "Reloc");
    client
        .attempt_pair_verify()
        .await
        .map_err(|e| format!("Remote Pairing 身份验证失败：{e}"))?;
    client
        .validate_pairing(&mut record)
        .await
        .map_err(|e| format!("配对记录校验未通过，请重新配对这台 iPhone：{e}"))?;

    let tunnel_port = client
        .create_tcp_listener()
        .await
        .map_err(|e| format!("无法创建设备加密隧道：{e}"))?;
    let key = client.encryption_key().to_vec();

    let tunnel_tcp = TcpStream::connect((host_ip, tunnel_port))
        .await
        .map_err(|e| format!("无法连接设备隧道端口 {tunnel_port}：{e}"))?;
    let _ = tunnel_tcp.set_nodelay(true);
    let cd = connect_tls_psk_tunnel_native(tunnel_tcp, &key)
        .await
        .map_err(|e| format!("TLS-PSK 隧道握手失败：{e}"))?;

    let our_ip: IpAddr = cd
        .info
        .client_address
        .parse()
        .map_err(|_| "隧道本地 IPv6 地址无效".to_string())?;
    let their_ip: IpAddr = cd
        .info
        .server_address
        .parse()
        .map_err(|_| "隧道设备 IPv6 地址无效".to_string())?;
    let rsd_port = cd.info.server_rsd_port;
    let mtu = cd.info.mtu as usize;

    let mut adapter = Adapter::new(Box::new(cd.into_inner()), our_ip, their_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut handle = adapter.to_async_handle();

    let rsd_stream = handle
        .connect(rsd_port)
        .await
        .map_err(|e| format!("无法连接 RSD 服务发现端口 {rsd_port}：{e}"))?;
    let rsd = RsdHandshake::new(rsd_stream)
        .await
        .map_err(|e| format!("RSD 服务发现握手失败：{e}"))?;

    Ok((client, handle, rsd))
}

async fn send_framed_plist<S: AsyncWrite + Unpin>(
    stream: &mut S,
    value: &plist::Value,
) -> Result<(), String> {
    let mut xml = Vec::new();
    plist::to_writer_xml(&mut xml, value).map_err(|e| format!("序列化 plist 失败：{e}"))?;
    let len = (xml.len() as u32).to_be_bytes();
    stream
        .write_all(&len)
        .await
        .map_err(|e| format!("写入 RSDCheckin 长度失败：{e}"))?;
    stream
        .write_all(&xml)
        .await
        .map_err(|e| format!("写入 RSDCheckin 数据失败：{e}"))?;
    stream
        .flush()
        .await
        .map_err(|e| format!("刷新 RSDCheckin 失败：{e}"))?;
    Ok(())
}

async fn recv_framed_plist<S: AsyncRead + Unpin>(stream: &mut S) -> Result<plist::Dictionary, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("读取 RSDCheckin 响应长度失败：{e}"))?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len == 0 || len > 4 * 1024 * 1024 {
        return Err(format!("RSDCheckin 响应长度异常：{len}"));
    }
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| format!("读取 RSDCheckin 响应体失败：{e}"))?;
    plist::from_bytes(&body).map_err(|e| format!("解析 RSDCheckin 响应失败：{e}"))
}

async fn perform_rsd_checkin<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Result<(), String> {
    let mut req = plist::Dictionary::new();
    req.insert("Label".into(), plist::Value::String("Reloc".into()));
    req.insert("ProtocolVersion".into(), plist::Value::String("2".into()));
    req.insert("Request".into(), plist::Value::String("RSDCheckin".into()));
    send_framed_plist(stream, &plist::Value::Dictionary(req)).await?;

    let first = recv_framed_plist(stream).await?;
    if first.get("Request").and_then(|v| v.as_string()) != Some("RSDCheckin") {
        return Err("RSDCheckin 握手回复异常".into());
    }
    let second = recv_framed_plist(stream).await?;
    if second.get("Request").and_then(|v| v.as_string()) != Some("StartService") {
        return Err("RSD StartService 握手回复异常".into());
    }
    Ok(())
}

async fn pair_on_device(request: Value, events: Events) -> Result<Value, String> {
    let mut record = match request["record"].as_str().filter(|s| !s.is_empty()) {
        Some(text) => {
            let bytes = BASE64_STANDARD
                .decode(text)
                .map_err(|_| "无法读取已保存的配对身份".to_string())?;
            RpPairingFile::from_bytes(&bytes)
                .map_err(|_| "已保存的配对身份无效，请重新导入".to_string())?
        }
        None => {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_err(|_| "系统时间无效".to_string())?
                .as_nanos();
            RpPairingFile::generate(&format!("Reloc-{nonce}"))
        }
    };

    if record.e_private_key.verifying_key() != record.e_public_key {
        return Err("配对身份的公私钥不匹配".into());
    }
    record.alt_irk = None;

    let mut info = PairableHostInfo::generate("Reloc", "Mac17,7");
    info.identifier = record.identifier().to_string();
    info.udid = record.identifier().to_string();
    if let Some(saved) = request["host_irk"]
        .as_str()
        .and_then(|s| BASE64_STANDARD.decode(s).ok())
    {
        if saved.len() == 16 {
            info.alt_irk.copy_from_slice(&saved);
        }
    }
    let host_irk = info.alt_irk;

    let listener = TcpListener::bind((std::net::Ipv4Addr::UNSPECIFIED, 0))
        .await
        .map_err(|e| format!("无法启动配对监听：{e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let txt: HashMap<String, String> = info
        .mdns_txt_records(record.identifier())
        .into_iter()
        .collect();
    events.send(json!({
        "type": "ready",
        "identifier": record.identifier(),
        "port": port,
        "txt": txt,
    }));

    let (stream, _) = listener
        .accept()
        .await
        .map_err(|e| format!("配对连接未建立：{e}"))?;
    events.send(json!({"type": "connected"}));

    let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
    let peer = host
        .accept(&mut record, move |pin| async move {
            events.send(json!({"type": "pin", "pin": pin}));
        })
        .await
        .map_err(|e| format!("设备配对未完成：{e}"))?;

    // Keep responder alive briefly while Settings commits the trusted host.
    tokio::time::sleep(Duration::from_millis(800)).await;

    Ok(json!({
        "type": "completed",
        "record": BASE64_STANDARD.encode(record.to_bytes()),
        "host_irk": BASE64_STANDARD.encode(host_irk),
        "udid": peer.remotepairing_udid,
        "device_name": peer.name,
        "device_model": peer.model,
    }))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rl_device_pairing_start(
    request: *const c_char,
    callback: Option<EventCallback>,
    context: *mut c_void,
) -> u64 {
    let Some(callback) = callback else { return 0 };
    if request.is_null() {
        return 0;
    }
    let text = unsafe { CStr::from_ptr(request) }.to_string_lossy();
    if text.len() > 3_000_000 {
        return 0;
    }
    let Ok(request) = serde_json::from_str::<Value>(&text) else {
        return 0;
    };

    static NEXT: AtomicU64 = AtomicU64::new(1);
    let id = NEXT.fetch_add(1, Ordering::Relaxed);
    let (cancel, cancelled) = oneshot::channel();
    pairing_sessions()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .insert(id, cancel);

    let events = Events {
        callback,
        context: context as usize,
    };

    runtime().spawn(async move {
        let result = tokio::select! {
            _ = cancelled => json!({"type": "cancelled"}),
            value = tokio::time::timeout(
                Duration::from_secs(300),
                std::panic::AssertUnwindSafe(pair_on_device(request, events)).catch_unwind()
            ) => match value {
                Ok(Ok(Ok(value))) => value,
                Ok(Ok(Err(error))) => json!({"type": "failed", "error": error}),
                Ok(Err(_)) => json!({"type": "failed", "error": "配对引擎已结束，请重试"}),
                Err(_) => json!({"type": "failed", "error": "配对等待超时，请返回 Reloc 重试"}),
            }
        };
        pairing_sessions()
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .remove(&id);
        events.send(result);
    });

    id
}

#[unsafe(no_mangle)]
pub extern "C" fn rl_device_pairing_cancel(id: u64) {
    if let Some(cancel) = pairing_sessions()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .remove(&id)
    {
        let _ = cancel.send(());
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rl_device_pairing_matches(
    record: *const u8,
    length: usize,
    identifier: *const c_char,
    tag: *const c_char,
) -> bool {
    if record.is_null() || identifier.is_null() || tag.is_null() || length > 2_000_000 {
        return false;
    }
    let Ok(record) = parse_rp_record(record, length) else {
        return false;
    };
    let Some(irk) = record.alt_irk() else {
        return false;
    };
    let id_str = unsafe { CStr::from_ptr(identifier) }.to_string_lossy();
    let tag_str = unsafe { CStr::from_ptr(tag) }.to_string_lossy();
    PeerDevice::validate_auth_tag(irk, &id_str, &tag_str)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rl_device_pairing_verify(
    record: *const u8,
    length: usize,
    host_ip: *const c_char,
    port: u16,
) -> *mut c_char {
    if host_ip.is_null() || port == 0 {
        return to_c_json(json!({"ok": false, "error": "设备连接参数无效"}));
    }
    let parsed = match parse_rp_record(record, length) {
        Ok(r) => r,
        Err(e) => return to_c_json(json!({"ok": false, "error": e})),
    };
    let host: IpAddr = match unsafe { CStr::from_ptr(host_ip) }
        .to_str()
        .ok()
        .and_then(|s| s.parse().ok())
    {
        Some(ip) => ip,
        None => return to_c_json(json!({"ok": false, "error": "回环 IP 地址无效"})),
    };

    let res = runtime().block_on(async move {
        let join = runtime().spawn(async move {
            tokio::time::timeout(Duration::from_secs(15), Box::pin(async move {
                let (_keep_client, mut handle, mut rsd) = establish_rsd(parsed, host, port).await?;
                let carkit = if rsd.services.contains_key("com.apple.carkit.service.shim.remote") {
                    Some("com.apple.carkit.service.shim.remote".to_string())
                } else if rsd.services.contains_key("com.apple.carkit.service") {
                    Some("com.apple.carkit.service".to_string())
                } else {
                    rsd.services
                        .keys()
                        .find(|k| k.contains("carkit"))
                        .cloned()
                };

                let mut udid = rsd.uuid.clone();
                if let Ok(mut ld) = LockdownClient::connect_rsd(&mut handle, &mut rsd).await {
                    if let Ok(val) = ld.get_value(Some("UniqueDeviceID"), None).await {
                        if let Some(s) = val.as_string() {
                            if !s.is_empty() {
                                udid = s.to_string();
                            }
                        }
                    }
                }

                Ok::<Value, String>(json!({
                    "ok": true,
                    "udid": udid,
                    "carkit_service": carkit,
                    "services_count": rsd.services.len(),
                }))
            }))
            .await
            .map_err(|_| "设备连接验证超时（请检查 10.7.0.1 回环代理是否已开启）".to_string())?
        });
        match join.await {
            Ok(inner) => inner,
            Err(_) => Err("设备连接验证任务异常中止".to_string()),
        }
    });

    match res {
        Ok(v) => to_c_json(v),
        Err(e) => to_c_json(json!({"ok": false, "error": e})),
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rl_rppairing_open_service(
    record: *const u8,
    length: usize,
    host_ip: *const c_char,
    port: u16,
    preferred_service: *const c_char,
) -> *mut c_char {
    if host_ip.is_null() || port == 0 {
        return to_c_json(json!({"ok": false, "error": "设备连接参数无效"}));
    }
    let parsed = match parse_rp_record(record, length) {
        Ok(r) => r,
        Err(e) => return to_c_json(json!({"ok": false, "error": e})),
    };
    let host: IpAddr = match unsafe { CStr::from_ptr(host_ip) }
        .to_str()
        .ok()
        .and_then(|s| s.parse().ok())
    {
        Some(ip) => ip,
        None => return to_c_json(json!({"ok": false, "error": "回环 IP 地址无效"})),
    };
    let preferred = if preferred_service.is_null() {
        "com.apple.carkit.service".to_string()
    } else {
        unsafe { CStr::from_ptr(preferred_service) }
            .to_string_lossy()
            .trim()
            .to_string()
    };

    let res = runtime().block_on(async move {
        let join = runtime().spawn(async move {
            tokio::time::timeout(Duration::from_secs(18), Box::pin(async move {
                let (rp_client, mut handle, mut rsd) = establish_rsd(parsed, host, port).await?;

                // Resolve target CarKit / iAP2 service over RSD or RSD-Lockdown.
                let candidates = [
                    preferred.as_str(),
                    "com.apple.carkit.service.shim.remote",
                    "com.apple.carkit.service",
                ];

                let mut chosen: Option<(String, u16, bool)> = None;
                for name in candidates {
                    if name.is_empty() {
                        continue;
                    }
                    if let Some(svc) = rsd.services.get(name) {
                        chosen = Some((name.to_string(), svc.port, name.ends_with(".shim.remote")));
                        break;
                    }
                }

                let (service_name, service_port, needs_checkin) = if let Some(found) = chosen {
                    found
                } else {
                    // Fallback: ask RSD lockdownd to start the service.
                    let mut ld = LockdownClient::connect_rsd(&mut handle, &mut rsd)
                        .await
                        .map_err(|e| format!("无法连接 RSD lockdownd：{e}"))?;
                    let target = if preferred.is_empty() {
                        "com.apple.carkit.service"
                    } else {
                        preferred.as_str()
                    };
                    let (svc_port, _ssl) = ld
                        .start_service(target)
                        .await
                        .map_err(|e| format!("无法启动服务 {target}：{e}"))?;
                    (target.to_string(), svc_port, false)
                };

                let mut remote_stream = handle
                    .connect(service_port)
                    .await
                    .map_err(|e| format!("无法连接服务 {service_name} (端口 {service_port})：{e}"))?;

                if needs_checkin {
                    perform_rsd_checkin(&mut remote_stream).await?;
                }

                let (client_unix, mut bridge_unix) =
                    UnixStream::pair().map_err(|e| format!("创建本地桥接通道失败：{e}"))?;
                let std_client = client_unix
                    .into_std()
                    .map_err(|e| format!("转换桥接句柄失败：{e}"))?;
                let raw_fd = std_client.into_raw_fd();

                static NEXT_TUNNEL: AtomicU64 = AtomicU64::new(1);
                let tunnel_id = NEXT_TUNNEL.fetch_add(1, Ordering::Relaxed);
                let (stop_tx, stop_rx) = oneshot::channel::<()>();
                active_tunnels()
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .insert(tunnel_id, stop_tx);

                // Keep both `rp_client` (control socket) and `handle` (jktcp adapter) alive
                // for the full duration of the service stream so iOS does not tear down the tunnel.
                tokio::spawn(async move {
                    let _keep_client = rp_client;
                    let _keep_adapter = handle;
                    tokio::select! {
                        _ = stop_rx => {}
                        _ = tokio::io::copy_bidirectional(&mut bridge_unix, &mut remote_stream) => {}
                    }
                    active_tunnels()
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .remove(&tunnel_id);
                });

                Ok::<Value, String>(json!({
                    "ok": true,
                    "handle": tunnel_id,
                    "fd": raw_fd,
                    "service": service_name,
                    "port": service_port,
                }))
            }))
            .await
            .map_err(|_| "打开设备服务连接超时".to_string())?
        });
        match join.await {
            Ok(inner) => inner,
            Err(_) => Err("打开设备服务任务异常中止".to_string()),
        }
    });

    match res {
        Ok(v) => to_c_json(v),
        Err(e) => to_c_json(json!({"ok": false, "error": e})),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn rl_rppairing_close_service(id: u64) {
    if let Some(stop_tx) = active_tunnels()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .remove(&id)
    {
        let _ = stop_tx.send(());
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn rl_string_free(value: *mut c_char) {
    if !value.is_null() {
        let _ = unsafe { CString::from_raw(value) };
    }
}
