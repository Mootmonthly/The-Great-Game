//! Encrypted connections (TLS 1.3 via rustls).
//!
//! The server presents either a real certificate (for a hosted server with
//! a domain) or a self-signed one it creates on first run. Clients accept a
//! certificate that a public authority vouches for; otherwise they pin the
//! server's certificate fingerprint the first time they connect (like SSH)
//! and refuse a different one later, which stops impostors.
//!
//! Each connection is split into a reader and a writer so one thread can
//! block reading while another writes. Both share the TLS state under a
//! lock that is never held while blocked on the network.

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::WebPkiServerVerifier;
use rustls::crypto::{ring, CryptoProvider};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime};
use rustls::{ClientConfig, Connection, DigitallySignedStruct, RootCertStore, ServerConfig, SignatureScheme};
use sha2::{Digest, Sha256};
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::path::Path;
use std::sync::{Arc, Mutex};

fn provider() -> Arc<CryptoProvider> {
    Arc::new(ring::default_provider())
}

/// SHA-256 of a certificate, as uppercase hex pairs separated by colons.
pub fn fingerprint(cert: &[u8]) -> String {
    Sha256::digest(cert)
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(":")
}

struct Io {
    conn: Mutex<Connection>,
    /// Writes to the socket happen in the order the TLS records were made.
    sock_w: Mutex<TcpStream>,
}

/// Takes every pending TLS record out of the connection.
fn pending(c: &mut Connection) -> io::Result<Vec<u8>> {
    let mut out = Vec::new();
    while c.wants_write() {
        c.write_tls(&mut out)?;
    }
    Ok(out)
}

/// Sends pending records. The socket lock is taken before the connection
/// lock is released, so records reach the wire in order.
fn send_pending(io: &Io, mut c: std::sync::MutexGuard<'_, Connection>) -> io::Result<()> {
    let bytes = pending(&mut c)?;
    if bytes.is_empty() {
        return Ok(());
    }
    let mut s = io.sock_w.lock().unwrap();
    drop(c);
    s.write_all(&bytes)?;
    s.flush()
}

pub struct TlsReader {
    io: Arc<Io>,
    sock: TcpStream,
}

pub struct TlsWriter {
    io: Arc<Io>,
}

impl Read for TlsReader {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        loop {
            {
                let mut c = self.io.conn.lock().unwrap();
                match c.reader().read(out) {
                    Ok(n) => return Ok(n),
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
                    Err(e) => return Err(e),
                }
                send_pending(&self.io, c)?;
            }
            let mut buf = [0u8; 16 * 1024];
            let n = self.sock.read(&mut buf)?;
            if n == 0 {
                return Ok(0);
            }
            let mut c = self.io.conn.lock().unwrap();
            let mut rest = &buf[..n];
            while !rest.is_empty() {
                c.read_tls(&mut rest)?;
                c.process_new_packets()
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
            }
            send_pending(&self.io, c)?;
        }
    }
}

impl Write for TlsWriter {
    fn write(&mut self, data: &[u8]) -> io::Result<usize> {
        let mut c = self.io.conn.lock().unwrap();
        let n = c.writer().write(data)?;
        send_pending(&self.io, c)?;
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        let mut c = self.io.conn.lock().unwrap();
        c.writer().flush()?;
        send_pending(&self.io, c)
    }
}

impl TlsWriter {
    /// Closes the connection for both directions.
    pub fn shutdown(&self) {
        let mut c = self.io.conn.lock().unwrap();
        c.send_close_notify();
        let _ = send_pending(&self.io, c);
        let _ = self.io.sock_w.lock().unwrap().shutdown(std::net::Shutdown::Both);
    }
}

fn split(conn: Connection, tcp: TcpStream) -> io::Result<(TlsReader, TlsWriter)> {
    tcp.set_nodelay(true)?;
    let io = Arc::new(Io {
        conn: Mutex::new(conn),
        sock_w: Mutex::new(tcp.try_clone()?),
    });
    Ok((
        TlsReader {
            io: io.clone(),
            sock: tcp,
        },
        TlsWriter { io },
    ))
}

/// The server side: a certificate and key.
pub struct TlsServer {
    config: Arc<ServerConfig>,
    /// Fingerprint of the server certificate, for players to check.
    pub fingerprint: String,
}

fn read_pem(path: &Path) -> io::Result<Vec<u8>> {
    std::fs::read(path)
}

impl TlsServer {
    /// Uses the given PEM certificate chain and private key.
    pub fn from_pem(cert_pem: &[u8], key_pem: &[u8]) -> io::Result<TlsServer> {
        let certs: Vec<CertificateDer<'static>> =
            rustls_pemfile::certs(&mut &cert_pem[..]).collect::<Result<_, _>>()?;
        let key: PrivateKeyDer<'static> = rustls_pemfile::private_key(&mut &key_pem[..])?
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "no private key in PEM"))?;
        let first = certs
            .first()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "no certificate in PEM"))?;
        let fingerprint = fingerprint(first.as_ref());
        let config = ServerConfig::builder_with_provider(provider())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(io::Error::other)?
            .with_no_client_auth()
            .with_single_cert(certs, key)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        Ok(TlsServer {
            config: Arc::new(config),
            fingerprint,
        })
    }

    /// Loads `cert.pem` and `key.pem` from `dir`, creating a self-signed
    /// certificate on first run so the fingerprint stays the same.
    pub fn self_signed_in(dir: &Path) -> io::Result<TlsServer> {
        let cert_path = dir.join("tls-cert.pem");
        let key_path = dir.join("tls-key.pem");
        if !cert_path.exists() || !key_path.exists() {
            let (cert, key) = self_signed()?;
            std::fs::write(&cert_path, cert)?;
            std::fs::write(&key_path, key)?;
        }
        TlsServer::from_pem(&read_pem(&cert_path)?, &read_pem(&key_path)?)
    }

    /// A throwaway self-signed certificate (tests, in-memory servers).
    pub fn ephemeral() -> io::Result<TlsServer> {
        let (cert, key) = self_signed()?;
        TlsServer::from_pem(cert.as_bytes(), key.as_bytes())
    }

    /// Wraps an accepted connection. The handshake runs on first use.
    pub fn accept(&self, tcp: TcpStream) -> io::Result<(TlsReader, TlsWriter)> {
        let conn = rustls::ServerConnection::new(self.config.clone())
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        split(Connection::Server(conn), tcp)
    }
}

fn self_signed() -> io::Result<(String, String)> {
    let cert = rcgen::generate_simple_self_signed(vec!["great-game-arena".to_string()])
        .map_err(io::Error::other)?;
    Ok((cert.cert.pem(), cert.key_pair.serialize_pem()))
}

/// Accepts certificates a public authority vouches for, or one matching the
/// pinned fingerprint, or (with no pin yet) any certificate: trust on first
/// use. Records the fingerprint it saw.
#[derive(Debug)]
struct PinVerifier {
    webpki: Arc<WebPkiServerVerifier>,
    pin: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        let fp = fingerprint(end_entity.as_ref());
        *self.seen.lock().unwrap() = Some(fp.clone());
        if self
            .webpki
            .verify_server_cert(end_entity, intermediates, server_name, ocsp, now)
            .is_ok()
        {
            return Ok(ServerCertVerified::assertion());
        }
        match &self.pin {
            Some(pin) if *pin != fp => Err(rustls::Error::General(
                "the server's certificate has changed since you last connected: it may be an impostor".into(),
            )),
            _ => Ok(ServerCertVerified::assertion()),
        }
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

/// A client connection. `seen` receives the server's certificate
/// fingerprint once the handshake has run, so the caller can pin it.
pub struct TlsClient {
    pub reader: TlsReader,
    pub writer: TlsWriter,
    pub seen: Arc<Mutex<Option<String>>>,
}

/// Starts TLS over `tcp` to `host`, pinning `pin` if known.
pub fn connect(tcp: TcpStream, host: &str, pin: Option<String>) -> io::Result<TlsClient> {
    let provider = provider();
    let roots = RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let webpki = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone())
        .build()
        .map_err(io::Error::other)?;
    let seen = Arc::new(Mutex::new(None));
    let verifier = PinVerifier {
        webpki,
        pin,
        seen: seen.clone(),
        provider: provider.clone(),
    };
    let config = ClientConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(io::Error::other)?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    let name = ServerName::try_from(host.to_string())
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let conn = rustls::ClientConnection::new(Arc::new(config), name)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    let (reader, writer) = split(Connection::Client(conn), tcp)?;
    Ok(TlsClient {
        reader,
        writer,
        seen,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;

    fn echo_server(server: TlsServer) -> std::net::SocketAddr {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        std::thread::spawn(move || {
            for tcp in listener.incoming().flatten() {
                let (r, mut w) = server.accept(tcp).unwrap();
                let mut r = BufReader::new(r);
                let mut line = String::new();
                if r.read_line(&mut line).is_ok() {
                    let _ = w.write_all(line.to_uppercase().as_bytes());
                }
            }
        });
        addr
    }

    fn talk(addr: std::net::SocketAddr, pin: Option<String>) -> io::Result<(String, Option<String>)> {
        let tcp = TcpStream::connect(addr)?;
        let mut c = connect(tcp, "127.0.0.1", pin)?;
        c.writer.write_all(b"hello\n")?;
        let mut line = String::new();
        BufReader::new(c.reader).read_line(&mut line)?;
        let seen = c.seen.lock().unwrap().clone();
        Ok((line, seen))
    }

    #[test]
    fn encrypted_round_trip_and_pinning() {
        let server = TlsServer::ephemeral().unwrap();
        let fp = server.fingerprint.clone();
        let addr = echo_server(server);
        // First contact: trust on first use, and learn the fingerprint.
        let (reply, seen) = talk(addr, None).unwrap();
        assert_eq!(reply, "HELLO\n");
        assert_eq!(seen.as_deref(), Some(fp.as_str()));
        // Pinned to the right certificate: fine.
        assert!(talk(addr, Some(fp)).is_ok());
        // Pinned to a different one: refused.
        assert!(talk(addr, Some("00:11".into())).is_err());
    }
}
