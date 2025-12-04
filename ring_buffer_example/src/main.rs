mod ring_buffer;
mod ring_buffer_seq;
use ring_buffer::RingBuf;
use ring_buffer_seq::RingBufSeq;
use std::thread;
use std::time::Instant;

trait RingBufferApi: Send + Sync + Clone + 'static {
    fn new(count: usize) -> Self;
    fn get_space_buf(&self) -> (u64, usize);
    fn produce(&self, count: usize) -> bool;
    fn get_data_buf(&self) -> (u64, usize);
    fn consume(&self, count: usize) -> bool;
    fn write(&mut self, buf: &[u8]) -> Result<(bool, usize), ring_buffer::Error>;
    fn read(&self, buf: &mut [u8]) -> Result<(bool, usize), ring_buffer::Error>;
}

impl RingBufferApi for RingBuf {
    fn new(count: usize) -> Self {
        RingBuf::new(count)
    }
    fn get_space_buf(&self) -> (u64, usize) {
        self.get_space_buf()
    }
    fn produce(&self, count: usize) -> bool {
        self.produce(count)
    }
    fn get_data_buf(&self) -> (u64, usize) {
        self.get_data_buf()
    }
    fn consume(&self, count: usize) -> bool {
        self.consume(count)
    }
    fn write(&mut self, buf: &[u8]) -> Result<(bool, usize), ring_buffer::Error> {
        self.write(buf)
    }
    fn read(&self, buf: &mut [u8]) -> Result<(bool, usize), ring_buffer::Error> {
        self.read(buf)
    }
}

impl RingBufferApi for RingBufSeq {
    fn new(count: usize) -> Self {
        RingBufSeq::new(count)
    }
    fn get_space_buf(&self) -> (u64, usize) {
        self.get_space_buf()
    }
    fn produce(&self, count: usize) -> bool {
        self.produce(count)
    }
    fn get_data_buf(&self) -> (u64, usize) {
        self.get_data_buf()
    }
    fn consume(&self, count: usize) -> bool {
        self.consume(count)
    }
    fn write(&mut self, buf: &[u8]) -> Result<(bool, usize), ring_buffer::Error> {
        self.write(buf)
            .map_err(|_| ring_buffer::Error::SysError(ring_buffer::SysErr::EINVAL))
    }
    fn read(&self, buf: &mut [u8]) -> Result<(bool, usize), ring_buffer::Error> {
        self.read(buf)
            .map_err(|_| ring_buffer::Error::SysError(ring_buffer::SysErr::EINVAL))
    }
}

fn run_benchmark_raw<T: RingBufferApi>(name: &str) {
    let count = 131072; // 1MB buffer
    let ring = T::new(count);
    let total_bytes = 1024 * 1024 * 128; // 1GB

    let producer_ring = ring.clone();
    let consumer_ring = ring.clone();

    println!(
        "Starting raw benchmark (get_space_buf/get_data_buf) for {}: 1GB transfer, 1MB ring buffer",
        name
    );
    let start = Instant::now();

    let producer_affinity = core_affinity::get_core_ids().unwrap()[12];
    let consumer_affinity = core_affinity::get_core_ids().unwrap()[14];

    let producer = thread::spawn(move || {
        core_affinity::set_for_current(producer_affinity);
        let mut produced = 0;
        while produced < total_bytes {
            let (addr, len) = producer_ring.get_space_buf();
            if len > 0 {
                // len is in bytes.
                // We want to transfer u64 elements.
                let len_items = len / 8;
                let total_items = total_bytes / 8;
                let produced_items = produced / 8;

                let to_write_items = std::cmp::min(len_items, total_items - produced_items);

                if to_write_items > 0 {
                    let ptr = addr as *mut u64;
                    unsafe {
                        for i in 0..to_write_items {
                            *ptr.add(i) = (produced_items + i) as u64;
                            producer_ring.produce(1 * 8);
                        }
                    }
                    produced += to_write_items * 8;
                } else {
                    thread::yield_now();
                }
            } else {
                thread::yield_now();
            }
        }
    });

    let consumer = thread::spawn(move || {
        core_affinity::set_for_current(consumer_affinity);
        let mut consumed = 0;
        while consumed < total_bytes {
            let (addr, len) = consumer_ring.get_data_buf();
            if len > 0 {
                let consumed_items = consumed / 8;
                let len_items = len / 8;

                if len_items > 0 {
                    let ptr = addr as *const u64;
                    unsafe {
                        // Verify data
                        for i in 0..len_items {
                            let expected = (consumed_items + i) as u64;
                            let val = *ptr.add(i);
                            if val != expected {
                                panic!(
                                    "Mismatch at index {}: expected {}, got {}",
                                    consumed_items + i,
                                    expected,
                                    val
                                );
                            }
                            consumer_ring.consume(1 * 8);
                        }
                    }
                    consumed += len_items * 8;
                } else {
                    thread::yield_now();
                }
            } else {
                thread::yield_now();
            }
        }
    });

    producer.join().unwrap();
    consumer.join().unwrap();

    let duration = start.elapsed();
    let mb = total_bytes as f64 / 1024.0 / 1024.0;
    let seconds = duration.as_secs_f64();
    println!("{}: Transferred {} MB in {:.4} seconds", name, mb, seconds);
    println!("{}: Throughput: {:.2} MB/s", name, mb / seconds);
    println!("--------------------------------------------------");
}

fn run_benchmark_read_write<T: RingBufferApi>(name: &str) {
    let count = 131072; // 1MB buffer
    let ring = T::new(count);
    let total_bytes = 1024 * 1024 * 8; // 8MB
    let chunk_size = 1; // 4KB

    let mut producer_ring = ring.clone();
    let consumer_ring = ring.clone();

    println!(
        "Starting read/write benchmark for {}: 1GB transfer, 1MB ring buffer, {}B chunks",
        name, chunk_size
    );
    let start = Instant::now();

    let producer_affinity = core_affinity::get_core_ids().unwrap()[12];
    let consumer_affinity = core_affinity::get_core_ids().unwrap()[14];

    let producer = thread::spawn(move || {
        core_affinity::set_for_current(producer_affinity);
        let data = vec![1u8; chunk_size];
        let mut written = 0;
        while written < total_bytes {
            let remaining = total_bytes - written;
            let to_write = if remaining < chunk_size {
                remaining
            } else {
                chunk_size
            };

            match producer_ring.write(&data[0..to_write]) {
                Ok((_, n)) => {
                    written += n;
                    if n == 0 {
                        thread::yield_now();
                    }
                }
                Err(_) => {
                    thread::yield_now();
                }
            }
        }
    });

    let consumer = thread::spawn(move || {
        core_affinity::set_for_current(consumer_affinity);
        let mut data = vec![0u8; chunk_size];
        let mut read = 0;
        while read < total_bytes {
            match consumer_ring.read(&mut data) {
                Ok((_, n)) => {
                    read += n;
                    if n == 0 {
                        thread::yield_now();
                    }
                }
                Err(_) => {
                    thread::yield_now();
                }
            }
        }
    });

    producer.join().unwrap();
    consumer.join().unwrap();

    let duration = start.elapsed();
    let mb = total_bytes as f64 / 1024.0 / 1024.0;
    let seconds = duration.as_secs_f64();
    println!("{}: Transferred {} MB in {:.4} seconds", name, mb, seconds);
    println!("{}: Throughput: {:.2} MB/s", name, mb / seconds);
    println!("--------------------------------------------------");
}

fn main() {
    run_benchmark_raw::<RingBuf>("RingBuf (Optimized)");
    run_benchmark_raw::<RingBufSeq>("RingBufSeq (Sequential)");

    run_benchmark_read_write::<RingBuf>("RingBuf (Optimized)");
    run_benchmark_read_write::<RingBufSeq>("RingBufSeq (Sequential)");
}
