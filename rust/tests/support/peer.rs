//! A loopback server that speaks just enough of the server side of RFC 6455 to exercise
//! the built-in transport: it does the upgrade by hand and then hands the raw socket over,
//! so a test can send exactly the bytes it means to — a masked frame, a fragment, a close
//! with no code — and read back exactly what the client wrote.

use std::fmt::Write as _;
use std::net::SocketAddr;
use std::time::Duration;

use actioncable::test_support::WAIT;
use actioncable::{Conn, DialOptions, Error, Transport, WebSocketTransport};
use http::{HeaderMap, HeaderName, HeaderValue};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Mutex, mpsc};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::handshake::derive_accept_key;

/// RFC 6455 §5.2's opcodes.
pub const OP_CONTINUATION: u8 = 0x0;
pub const OP_TEXT: u8 = 0x1;
pub const OP_BINARY: u8 = 0x2;
pub const OP_CLOSE: u8 = 0x8;
pub const OP_PING: u8 = 0x9;
pub const OP_PONG: u8 = 0xa;

/// A server on the loopback interface, and the connections a test plays the server on.
pub struct TestServer {
    address: SocketAddr,
    accepted: Mutex<mpsc::UnboundedReceiver<Peer>>,
    _accepting: JoinHandle<()>,
}

impl TestServer {
    /// A server that completes the upgrade and picks the first subprotocol offered.
    pub async fn start() -> TestServer {
        TestServer::listening(Upgrade::Correct).await
    }

    /// A server that completes the upgrade with a `Sec-WebSocket-Accept` that isn't the
    /// one the key hashes to.
    pub async fn with_a_bad_accept_key() -> TestServer {
        TestServer::listening(Upgrade::BadAcceptKey).await
    }

    /// A server that answers the upgrade request with a canned HTTP response and hangs up.
    pub async fn answering(response: &'static str) -> TestServer {
        TestServer::listening(Upgrade::Refused(response)).await
    }

    async fn listening(upgrade: Upgrade) -> TestServer {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (hand_over, accepted) = mpsc::unbounded_channel();

        let accepting = tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                if let Some(peer) = upgrade.answer(socket).await {
                    let _handed = hand_over.send(peer);
                }
            }
        });

        TestServer {
            address,
            accepted: Mutex::new(accepted),
            _accepting: accepting,
        }
    }

    pub fn url(&self) -> String {
        format!("ws://{}/cable", self.address)
    }

    /// Dials the server with the built-in transport, expecting it to get through.
    pub async fn dial(&self, subprotocols: Vec<String>, headers: HeaderMap) -> Box<dyn Conn> {
        WebSocketTransport::new()
            .dial(
                &self.url(),
                DialOptions {
                    subprotocols,
                    headers,
                },
            )
            .await
            .expect("the dial should have got through")
    }

    /// Dials with a transport configured differently.
    pub async fn dial_with(
        &self,
        configure: impl FnOnce(WebSocketTransport) -> WebSocketTransport,
    ) -> Box<dyn Conn> {
        configure(WebSocketTransport::new())
            .dial(&self.url(), DialOptions::default())
            .await
            .expect("the dial should have got through")
    }

    /// Dials without expecting it to work, and keeps only whether it did.
    pub async fn try_dial(&self) -> Result<(), Error> {
        WebSocketTransport::new()
            .dial(&self.url(), DialOptions::default())
            .await
            .map(|_connected| ())
    }

    /// The next connection the client opened.
    pub async fn accept(&self) -> Peer {
        tokio::time::timeout(WAIT, self.accepted.lock().await.recv())
            .await
            .expect("no client connected")
            .expect("the listener went away")
    }
}

/// What the server does with an upgrade request.
#[derive(Clone, Copy)]
enum Upgrade {
    Correct,
    BadAcceptKey,
    Refused(&'static str),
}

impl Upgrade {
    async fn answer(self, mut socket: TcpStream) -> Option<Peer> {
        let request = read_request(&mut socket).await;
        let (path, headers) = parse_request(&request);

        if let Upgrade::Refused(response) = self {
            socket.write_all(response.as_bytes()).await.unwrap();
            let _flushed = socket.flush().await;
            return None;
        }

        let key = headers
            .get("sec-websocket-key")
            .expect("the client sent no Sec-WebSocket-Key");
        let accepted = match self {
            Upgrade::BadAcceptKey => "obviously-wrong".to_string(),
            _ => derive_accept_key(key.as_bytes()),
        };

        let mut response = format!(
            "HTTP/1.1 101 Switching Protocols\r\n\
             Upgrade: websocket\r\n\
             Connection: Upgrade\r\n\
             Sec-WebSocket-Accept: {accepted}\r\n"
        );
        if let Some(offered) = headers.get("sec-websocket-protocol") {
            let first = offered.to_str().unwrap().split(',').next().unwrap().trim();
            write!(response, "Sec-WebSocket-Protocol: {first}\r\n").unwrap();
        }
        response.push_str("\r\n");
        socket.write_all(response.as_bytes()).await.unwrap();

        Some(Peer {
            socket,
            path,
            headers,
        })
    }
}

async fn read_request(socket: &mut TcpStream) -> String {
    let mut request = Vec::new();
    let mut byte = [0_u8; 1];
    while !request.ends_with(b"\r\n\r\n") {
        match socket.read(&mut byte).await {
            Ok(0) | Err(_) => break,
            Ok(_) => request.push(byte[0]),
        }
    }

    String::from_utf8_lossy(&request).into_owned()
}

fn parse_request(request: &str) -> (String, HeaderMap) {
    let mut lines = request.split("\r\n");
    let path = lines
        .next()
        .and_then(|line| line.split(' ').nth(1))
        .unwrap_or_default()
        .to_string();

    let mut headers = HeaderMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(": ")
            && let (Ok(name), Ok(value)) = (
                name.parse::<HeaderName>(),
                HeaderValue::from_str(value.trim()),
            )
        {
            headers.insert(name, value);
        }
    }

    (path, headers)
}

/// One upgraded connection, with the test on the server's end of it.
pub struct Peer {
    socket: TcpStream,
    pub path: String,
    headers: HeaderMap,
}

impl Peer {
    /// What the upgrade request carried, which the test usually asserts on.
    pub fn header(&self, name: &str) -> &str {
        self.headers
            .get(name)
            .unwrap_or_else(|| panic!("the request carried no {name}"))
            .to_str()
            .unwrap()
    }

    /// Sends one whole frame, unmasked as a server must.
    pub async fn write(&mut self, opcode: u8, payload: &[u8]) {
        self.write_fragment(opcode, payload, true).await;
    }

    /// Sends one frame of a fragmented message.
    pub async fn write_fragment(&mut self, opcode: u8, payload: &[u8], final_frame: bool) {
        let mut frame = vec![if final_frame { 0x80 | opcode } else { opcode }];
        push_length(&mut frame, payload.len(), 0);
        frame.extend_from_slice(payload);

        let _written = self.socket.write_all(&frame).await;
    }

    /// Sends a frame the way only a client is allowed to: masked.
    pub async fn write_masked(&mut self, opcode: u8, payload: &[u8]) {
        let mask = [1_u8, 2, 3, 4];
        let mut frame = vec![0x80 | opcode];
        push_length(&mut frame, payload.len(), 0x80);
        frame.extend_from_slice(&mask);
        frame.extend(
            payload
                .iter()
                .enumerate()
                .map(|(index, byte)| byte ^ mask[index % 4]),
        );

        let _written = self.socket.write_all(&frame).await;
    }

    /// The next frame the client sent, unmasked.
    pub async fn read_frame(&mut self) -> (u8, Vec<u8>) {
        tokio::time::timeout(WAIT, self.next_frame())
            .await
            .expect("the client sent nothing")
            .expect("the client hung up")
    }

    /// The next frame, which has to be text.
    pub async fn read_text(&mut self) -> String {
        let (opcode, payload) = self.read_frame().await;
        assert_eq!(OP_TEXT, opcode, "expected a text frame");

        String::from_utf8(payload).unwrap()
    }

    /// How many close frames the client sends before it falls quiet. The socket itself
    /// goes when the connection is dropped, which is later than this and not what the
    /// count is about.
    pub async fn close_frames(&mut self) -> usize {
        let mut closes = 0;
        while let Ok(Some((opcode, _))) =
            tokio::time::timeout(Duration::from_millis(200), self.next_frame()).await
        {
            if opcode == OP_CLOSE {
                closes += 1;
            }
        }

        closes
    }

    async fn next_frame(&mut self) -> Option<(u8, Vec<u8>)> {
        let mut header = [0_u8; 2];
        self.socket.read_exact(&mut header).await.ok()?;

        let opcode = header[0] & 0x0f;
        let masked = header[1] & 0x80 != 0;
        assert!(masked, "a client must mask everything it sends");

        let length = match header[1] & 0x7f {
            126 => {
                let mut extended = [0_u8; 2];
                self.socket.read_exact(&mut extended).await.ok()?;
                u64::from(u16::from_be_bytes(extended))
            }
            127 => {
                let mut extended = [0_u8; 8];
                self.socket.read_exact(&mut extended).await.ok()?;
                u64::from_be_bytes(extended)
            }
            length => u64::from(length),
        };

        let mut mask = [0_u8; 4];
        self.socket.read_exact(&mut mask).await.ok()?;

        let mut payload = vec![0_u8; usize::try_from(length).unwrap()];
        self.socket.read_exact(&mut payload).await.ok()?;
        for (index, byte) in payload.iter_mut().enumerate() {
            *byte ^= mask[index % 4];
        }

        Some((opcode, payload))
    }
}

/// RFC 6455 §5.2's length, in the shortest form that holds it, with the mask bit the
/// sender is allowed to set.
fn push_length(frame: &mut Vec<u8>, length: usize, mask_bit: u8) {
    if length <= 125 {
        frame.push(mask_bit | u8::try_from(length).unwrap());
    } else if let Ok(length) = u16::try_from(length) {
        frame.push(mask_bit | 0x7e);
        frame.extend_from_slice(&length.to_be_bytes());
    } else {
        frame.push(mask_bit | 0x7f);
        frame.extend_from_slice(&(length as u64).to_be_bytes());
    }
}
