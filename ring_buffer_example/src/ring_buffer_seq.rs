#![allow(dead_code)]
use std::{
    cell::UnsafeCell,
    fmt, slice, str,
    sync::{
        Arc,
        atomic::{AtomicU32, Ordering},
    },
};

#[derive(Debug)]
pub enum SysErr {
    EINVAL,
}

#[derive(Debug)]
pub enum Error {
    SysError(SysErr),
    QueueFull,
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, Copy)]
pub struct Iov {
    pub start: u64,
    pub len: usize,
}

pub struct SocketBufIovs<'a> {
    pub iovs: &'a mut [Iov],
    pub cnt: usize,
}

#[derive(Clone)]
pub struct RingBufSeq {
    pub buf: Arc<Vec<UnsafeCell<u64>>>,
    pub ring_mask: u32,
    pub head: Arc<AtomicU32>,
    pub tail: Arc<AtomicU32>,
}

unsafe impl Send for RingBufSeq {}
unsafe impl Sync for RingBufSeq {}

impl fmt::Debug for RingBufSeq {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(
            f,
            "RingBuf buf {:?} head/tail {:x?}/{:x?}",
            *self.buf, self.head, self.tail
        )
    }
}

impl RingBufSeq {
    pub fn is_power_of_two(x: usize) -> bool {
        return (x & (x - 1)) == 0;
    }

    pub fn new(count: usize) -> Self {
        return Self {
            buf: Arc::new((0..count).map(|_| UnsafeCell::new(0)).collect()),
            ring_mask: ((count * 8) - 1) as u32,
            head: Arc::new(AtomicU32::new(0)),
            tail: Arc::new(AtomicU32::new(0)),
        };
    }

    //return (bufAddr, bufSize)
    pub fn get_raw_buf(&self) -> (&Vec<UnsafeCell<u64>>, usize) {
        return (&self.buf, self.len());
    }

    #[inline]
    pub fn len(&self) -> usize {
        return (self.ring_mask + 1) as usize;
    }

    #[inline]
    pub fn buf(&self) -> &mut [u8] {
        let ptr = self.buf.as_ptr() as *mut u8;
        let len = self.buf.len() * 8;
        unsafe { slice::from_raw_parts_mut(ptr, len) }
    }

    pub fn available_data_size(&self) -> usize {
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);
        return tail.wrapping_sub(head) as usize;
    }

    pub fn available_space(&self) -> usize {
        return self.len() - self.available_data_size();
    }

    /****************************************** read *********************************************************/
    //return (initial size is full, how much read)
    pub fn read(&self, buf: &mut [u8]) -> Result<(bool, usize)> {
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let mut available = tail.wrapping_sub(head) as usize;
        let full = available == self.len();

        if available > buf.len() {
            available = buf.len();
        }

        let read_pos = (head & self.ring_mask) as usize;
        let (first_len, has_second) = {
            let to_end = self.len() - read_pos;
            if to_end < available {
                (to_end, true)
            } else {
                (available, false)
            }
        };

        buf[0..first_len].copy_from_slice(&self.buf()[read_pos..read_pos + first_len]);

        if has_second {
            let second_len = available - first_len;
            buf[first_len..first_len + second_len].copy_from_slice(&self.buf()[0..second_len])
        }

        self.head
            .store(head.wrapping_add(available as u32), Ordering::SeqCst);
        return Ok((full, available));
    }

    pub fn read_via_addr(&self, buf: u64, count: u64) -> (bool, usize) {
        let ptr = buf as *mut u8;
        let slice = unsafe { slice::from_raw_parts_mut(ptr, count as usize) };
        let res = self.read(slice).expect("read_via_addr get error");
        return res;
    }

    //return addr, len, whethere there is more space
    pub fn get_read_buf(&self) -> Option<(u64, usize, bool)> {
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let available = tail.wrapping_sub(head) as usize;

        if available == 0 {
            return None;
        }

        let read_pos = (head & self.ring_mask) as usize;
        let to_end = self.len() - read_pos;
        if to_end < available {
            return Some((self.buf.as_ptr() as u64 + read_pos as u64, to_end, true));
        } else {
            return Some((self.buf.as_ptr() as u64 + read_pos as u64, available, false));
        }
    }

    pub fn get_data_buf(&self) -> (u64, usize) {
        //TODO: Revisit memory order to loose constraints
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let available = tail.wrapping_sub(head) as usize;

        if available == 0 {
            return (0, 0);
        }

        let read_pos = (head & self.ring_mask) as usize;
        let to_end = self.len() - read_pos;
        if to_end < available {
            return (self.buf.as_ptr() as u64 + read_pos as u64, to_end);
        } else {
            return (self.buf.as_ptr() as u64 + read_pos as u64, available);
        }
    }

    pub fn prepare_data_iovs(&self, data: &mut SocketBufIovs) {
        let iovs = &mut data.iovs;

        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let available = tail.wrapping_sub(head) as usize;

        if available == 0 {
            data.cnt = 0;
            return;
        }

        assert!(iovs.len() >= 2);
        let read_pos = (head & self.ring_mask) as usize;
        let to_end = self.len() - read_pos;
        if to_end < available {
            iovs[0].start = &self.buf()[read_pos as usize] as *const _ as u64;
            iovs[0].len = to_end as usize;

            iovs[1].start = &self.buf()[0] as *const _ as u64;
            iovs[1].len = available - to_end;

            data.cnt = 2;
        } else {
            iovs[0].start = &self.buf()[read_pos as usize] as *const _ as u64;
            iovs[0].len = available as usize;

            data.cnt = 1;
        }
    }

    pub fn consume_with_check(&self, count: usize) -> Result<bool> {
        let available = self.available_data_size();
        if available < count {
            return Err(Error::SysError(SysErr::EINVAL));
        }

        let trigger = self.consume(count);
        return Ok(trigger);
    }

    //consume count data
    pub fn consume(&self, count: usize) -> bool {
        //2
        //TODO: Revisit memory order to loose constraints
        let head = self.head.load(Ordering::SeqCst);
        self.head
            .store(head.wrapping_add(count as u32), Ordering::SeqCst);

        let tail = self.tail.load(Ordering::SeqCst);
        let available = tail.wrapping_sub(head) as usize;
        let trigger = available == self.len();
        return trigger;
    }
    /****************************************** write *********************************************************/

    pub fn get_write_buf(&self) -> Option<(u64, usize, bool)> {
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let available = tail.wrapping_sub(head) as usize;
        if available == self.len() {
            return None;
        }

        let write_pos = (tail & self.ring_mask) as usize;
        let write_size = self.len() - available;

        let to_end = self.len() - write_pos;
        if to_end < write_size {
            return Some((self.buf.as_ptr() as u64 + write_pos as u64, to_end, true));
        } else {
            return Some((
                self.buf.as_ptr() as u64 + write_pos as u64,
                write_size,
                false,
            ));
        }
    }

    pub fn prepare_space_iovs(&self, data: &mut SocketBufIovs) {
        let iovs = &mut data.iovs;

        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);
        let available = tail.wrapping_sub(head) as usize;

        if available == self.len() {
            data.cnt = 0;
            return;
        }

        //error!("GetSpaceIovs available is {}", self.available);
        assert!(iovs.len() >= 2);
        let write_pos = (tail & self.ring_mask) as usize;
        let write_size = self.len() - available;

        let to_end = self.len() - write_pos;

        //error!("GetSpaceIovs available is {}, toEnd is {}", self.available, toEnd);
        if to_end < write_size {
            iovs[0].start = &self.buf()[write_pos as usize] as *const _ as u64;
            iovs[0].len = to_end as usize;

            iovs[1].start = &self.buf()[0] as *const _ as u64;
            iovs[1].len = write_size - to_end;

            data.cnt = 2;
        } else {
            iovs[0].start = &self.buf()[write_pos as usize] as *const _ as u64;
            iovs[0].len = write_size as usize;

            data.cnt = 1;
        }
    }

    pub fn get_space_buf(&self) -> (u64, usize) {
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let available = tail.wrapping_sub(head) as usize;
        if available == self.len() {
            return (0, 0);
        }

        let write_pos = (tail & self.ring_mask) as usize;
        let write_size = self.len() - available;

        let to_end = self.len() - write_pos;
        if to_end < write_size {
            return (self.buf.as_ptr() as u64 + write_pos as u64, to_end);
        } else {
            return (self.buf.as_ptr() as u64 + write_pos as u64, write_size);
        }
    }

    pub fn produce_with_check(&self, count: usize) -> Result<bool> {
        let available = self.available_data_size();
        if available + count > self.len() {
            return Err(Error::SysError(SysErr::EINVAL));
        }

        let trigger = self.produce(count);
        return Ok(trigger);
    }

    pub fn produce(&self, count: usize) -> bool {
        //TODO: Revisit memory order to loose constraints
        let tail = self.tail.load(Ordering::SeqCst);
        self.tail
            .store(tail.wrapping_add(count as u32), Ordering::SeqCst);

        let head = self.head.load(Ordering::SeqCst);
        let available = tail.wrapping_sub(head) as usize;
        let trigger = available == 0;
        return trigger;
    }

    /// return: write user buffer to socket bytestream and determine whether to trigger async socket ops
    pub fn write(&mut self, buf: &[u8]) -> Result<(bool, usize)> {
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let available = tail.wrapping_sub(head) as usize;

        let empty = available == 0;

        let write_pos = (tail & self.ring_mask) as usize;
        let mut write_size = self.len() - available;

        if write_size > buf.len() {
            write_size = buf.len();
        }

        let (first_len, has_second) = {
            let to_end = self.len() - write_pos;
            if to_end < write_size {
                (to_end, true)
            } else {
                (write_size, false)
            }
        };

        self.buf()[write_pos..write_pos + first_len].copy_from_slice(&buf[0..first_len]);

        if has_second {
            let second_len = write_size - first_len;
            self.buf()[0..second_len].copy_from_slice(&buf[first_len..first_len + second_len]);
        }

        self.tail
            .store(tail.wrapping_add(write_size as u32), Ordering::SeqCst);
        return Ok((empty, write_size));
    }

    pub fn write_full(&mut self, buf: &[u8]) -> Result<(bool, usize)> {
        let head = self.head.load(Ordering::SeqCst);
        let tail = self.tail.load(Ordering::SeqCst);

        let available = tail.wrapping_sub(head) as usize;
        let space = self.len() - available;

        if available < buf.len() {
            let str = str::from_utf8(buf).unwrap();
            print!("write full {}/{}/{}", space, buf.len(), str);
            return Err(Error::QueueFull);
        }

        return self.write(buf);
    }

    pub fn write_via_addr(&mut self, buf: u64, count: u64) -> (bool, usize) {
        let ptr = buf as *const u8;
        let slice = unsafe { slice::from_raw_parts(ptr, count as usize) };
        self.write(slice).expect("write_via_addr fail")
    }
}
