//! Length-prefixed framing: a 4-byte big-endian u32 length, then the payload.

use crate::MAX_FRAME_LEN;
use std::io::{self, Read, Write};

fn too_large(n: u64) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, format!("frame too large: {n}"))
}

fn payload_len(header: [u8; 4]) -> io::Result<usize> {
    let n = u32::from_be_bytes(header);
    if n > MAX_FRAME_LEN {
        return Err(too_large(u64::from(n)));
    }
    Ok(n as usize)
}

fn header(payload: &[u8]) -> io::Result<[u8; 4]> {
    if payload.len() as u64 > u64::from(MAX_FRAME_LEN) {
        return Err(too_large(payload.len() as u64));
    }
    #[expect(clippy::cast_possible_truncation, reason = "the length was checked against MAX_FRAME_LEN above")]
    let len = payload.len() as u32;
    Ok(len.to_be_bytes())
}

pub fn read_sync(r: &mut impl Read) -> io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let mut buf = vec![0u8; payload_len(len)?];
    r.read_exact(&mut buf)?;
    Ok(buf)
}

pub fn write_sync(w: &mut impl Write, payload: &[u8]) -> io::Result<()> {
    w.write_all(&header(payload)?)?;
    w.write_all(payload)
}

#[cfg(feature = "async")]
pub async fn read_async(r: &mut (impl tokio::io::AsyncRead + Unpin)) -> io::Result<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    let mut len = [0u8; 4];
    r.read_exact(&mut len).await?;
    let mut buf = vec![0u8; payload_len(len)?];
    r.read_exact(&mut buf).await?;
    Ok(buf)
}

#[cfg(feature = "async")]
pub async fn write_async(w: &mut (impl tokio::io::AsyncWrite + Unpin), payload: &[u8]) -> io::Result<()> {
    use tokio::io::AsyncWriteExt;
    w.write_all(&header(payload)?).await?;
    w.write_all(payload).await
}

/// `msg`, encoded and framed.
#[cfg(feature = "async")]
pub async fn write_msg_async(w: &mut (impl tokio::io::AsyncWrite + Unpin), msg: &crate::Msg) -> io::Result<()> {
    let payload = crate::encode(msg).map_err(io::Error::other)?;
    write_async(w, &payload).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Msg, encode};

    #[test]
    fn frame_roundtrip_and_oversize_rejection() {
        let payload = encode(&Msg::Ack).unwrap();
        let mut buf = Vec::new();
        write_sync(&mut buf, &payload).unwrap();
        #[expect(clippy::cast_possible_truncation, reason = "predates the lint; decided in #470")]
        let len = payload.len() as u32;
        assert_eq!(&buf[..4], &len.to_be_bytes());
        let mut cursor = io::Cursor::new(buf);
        assert_eq!(read_sync(&mut cursor).unwrap(), payload);

        let mut oversize = Vec::new();
        oversize.extend_from_slice(&(MAX_FRAME_LEN + 1).to_be_bytes());
        let mut cursor = io::Cursor::new(oversize);
        let err = read_sync(&mut cursor).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn a_frame_of_exactly_the_limit_is_taken_and_one_byte_more_is_refused() {
        let limit = MAX_FRAME_LEN as usize;
        assert_eq!(payload_len(MAX_FRAME_LEN.to_be_bytes()).unwrap(), limit);
        assert_eq!(payload_len((MAX_FRAME_LEN + 1).to_be_bytes()).unwrap_err().kind(), io::ErrorKind::InvalidData);

        let mut payload = vec![0u8; limit];
        assert_eq!(header(&payload).unwrap(), MAX_FRAME_LEN.to_be_bytes());
        assert_eq!(header(&payload[..limit - 1]).unwrap(), (MAX_FRAME_LEN - 1).to_be_bytes());
        payload.push(0);
        assert_eq!(header(&payload).unwrap_err().kind(), io::ErrorKind::InvalidData);
    }

    /// Runs a future whose reader and writer are in memory, so it never waits.
    #[cfg(feature = "async")]
    fn now<T>(future: impl Future<Output = T>) -> T {
        let mut future = std::pin::pin!(future);
        match future.as_mut().poll(&mut std::task::Context::from_waker(std::task::Waker::noop())) {
            std::task::Poll::Ready(value) => value,
            std::task::Poll::Pending => panic!("a read or a write in memory waited"),
        }
    }

    #[cfg(feature = "async")]
    #[test]
    fn the_async_frame_is_the_sync_frame() {
        let payload = encode(&Msg::Ack).unwrap();
        let mut framed = Vec::new();
        write_sync(&mut framed, &payload).unwrap();

        let mut written = Vec::new();
        now(write_async(&mut written, &payload)).unwrap();
        assert_eq!(written, framed);

        let mut message = Vec::new();
        now(write_msg_async(&mut message, &Msg::Ack)).unwrap();
        assert_eq!(message, framed);

        assert_eq!(now(read_async(&mut framed.as_slice())).unwrap(), payload);
        let oversize = (MAX_FRAME_LEN + 1).to_be_bytes();
        assert_eq!(now(read_async(&mut oversize.as_slice())).unwrap_err().kind(), io::ErrorKind::InvalidData);
    }
}
