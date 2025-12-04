mod ring_buffer;
mod ring_buffer_seq;
use ring_buffer::RingBuf;
use ring_buffer_seq::RingBufSeq;
use std::thread;
use std::time::Instant;

fn main() {
    // 1MB buffer (131072 * 8 bytes = 1MB)
    let count = 131072;
    // let ring = RingBufSeq::new(count);
    let ring = RingBuf::new(count);

    let total_bytes = 1024 * 1024 * 16;
    let chunk_size = 1; // 4KB chunks

    let mut ring_producer = ring.clone();
    let ring_consumer = ring.clone();

    println!(
        "Starting benchmark: {}GB transfer, 1MB ring buffer, {}B chunks",
        total_bytes / 1024 / 1024,
        chunk_size * size_of::<u64>()
    );
    let start = Instant::now();

    let producer_affinity = core_affinity::get_core_ids().unwrap()[12];
    let consumer_affinity = core_affinity::get_core_ids().unwrap()[14];

    let producer = thread::spawn(move || {
        core_affinity::set_for_current(producer_affinity);
        let data = vec![1u8; chunk_size];
        let mut written = 0;
        while written < total_bytes {
            // We want to write 'chunk_size' or remaining bytes
            let remaining = total_bytes - written;
            let to_write = if remaining < chunk_size {
                remaining
            } else {
                chunk_size
            };

            match ring_producer.write(&data[0..to_write]) {
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
            match ring_consumer.read(&mut data) {
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
    println!("Transferred {} MB in {:.4} seconds", mb, seconds);
    println!("Throughput: {:.2} MB/s", mb / seconds);
}
