use clap::Parser;
use rand::{RngCore, SeedableRng};
use rand::rngs::StdRng;
use std::{
    fs::{File, OpenOptions, remove_file},
    io::{Write, Read, Seek, SeekFrom, Result as IoResult},
    path::PathBuf,
    time::{Instant, Duration, SystemTime, UNIX_EPOCH},
    sync::atomic::{AtomicBool, Ordering},
    thread,
    process,
};

static SIGNAL_RECEIVED: AtomicBool = AtomicBool::new(false);
static mut TEST_FILE_PATH: Option<String> = None;

#[derive(Parser)]
#[command(name = "ssd-write-test")]
#[command(about = "SSD sustained write speed test")]
struct Opt {
    #[arg(short = 'd', long = "directory", default_value = ".", help = "Target directory")]
    target: PathBuf,

    #[arg(short = 'r', long = "ratio", default_value_t = 1.0, help = "Size ratio of available space to use (0.0-1.0)")]
    ratio: f64,

    #[arg(short = 'c', long = "chunk-size", default_value_t = 10 * 1024 * 1024, help = "Chunk size in bytes")]
    chunk_size: usize,

    #[arg(short = 'o', long = "output", default_value = "result.csv", help = "Output CSV file")]
    csv: PathBuf,

    #[arg(short = 'v', long = "verify", help = "Verify data after write")]
    verify: bool,
}

struct RandomGenerator {
    rng: StdRng,
    buffer: Vec<u8>,
}

impl RandomGenerator {
    fn new(buffer_size: usize, seed: Option<u64>) -> Self {
        let rng = if let Some(seed) = seed {
            StdRng::seed_from_u64(seed)
        } else {
            let seed = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos() as u64;
            StdRng::seed_from_u64(seed)
        };

        Self {
            rng,
            buffer: vec![0u8; buffer_size],
        }
    }

    fn fill_buffer(&mut self, seed: Option<u64>) {
        if let Some(seed) = seed {
            self.rng = StdRng::seed_from_u64(seed);
        }
        self.rng.fill_bytes(&mut self.buffer);
    }

    fn get_data(&self) -> &[u8] {
        &self.buffer
    }
}

fn get_available_space(path: &PathBuf) -> IoResult<u64> {
    let canonical_path = path.canonicalize()?;
    let _root = canonical_path
        .components()
        .next()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::InvalidInput, "Invalid path"))?;

    let mut test_path = canonical_path.clone();
    test_path.push("test_space_check.tmp");

    match File::create(&test_path) {
        Ok(_) => {
            let _ = remove_file(&test_path);
            Ok(10 * 1024 * 1024 * 1024)
        }
        Err(e) => Err(e),
    }
}

fn setup_signal_handler() {
    let _ = ctrlc::set_handler(move || {
        if SIGNAL_RECEIVED.load(Ordering::Relaxed) {
            println!("\nTerminating immediately.");
            process::exit(1);
        }

        SIGNAL_RECEIVED.store(true, Ordering::Relaxed);
        println!("\nReceived interrupt signal. Cleaning up test file...");
        println!("Press Ctrl+C again to force immediate termination.");

        unsafe {
            if let Some(ref file_path) = TEST_FILE_PATH {
                let _ = remove_file(file_path);
                println!("Test file cleaned up.");
            }
        }

        std::thread::spawn(|| {
            std::thread::sleep(Duration::from_secs(1));
            process::exit(0);
        });
    });
}

fn open_file_for_direct_write(path: &PathBuf, verify: bool) -> IoResult<File> {
    let mut options = OpenOptions::new();
    options.create(true).truncate(true);

    if verify {
        options.read(true).write(true)
    } else {
        options.write(true)
    };

    let file = options.open(path)?;
    Ok(file)
}

fn write_chunk_with_sync(file: &mut File, data: &[u8]) -> IoResult<()> {
    file.write_all(data)?;
    file.sync_all()?;
    Ok(())
}

fn verify_written_data(
    file: &mut File,
    config: &Opt,
    number_of_chunks: usize,
    original_chunks: &[Vec<u8>]
) -> IoResult<(bool, f64)> {
    println!("\nStarting data verification...");

    file.seek(SeekFrom::Start(0))?;

    let mut read_buffer = vec![0u8; config.chunk_size];
    let mut verification_errors = 0;
    let max_errors_to_report = 10;
    let mut total_bytes_read = 0u64;

    let verification_start_time = Instant::now();

    println!("Verifying {} chunks...", number_of_chunks);

    for chunk_index in 0..number_of_chunks {
        if SIGNAL_RECEIVED.load(Ordering::Relaxed) {
            break;
        }

        let expected_data = &original_chunks[chunk_index];

        let bytes_read = file.read(&mut read_buffer)?;

        if bytes_read != config.chunk_size {
            if verification_errors < max_errors_to_report {
                println!("Error: Read mismatch at chunk {} - expected {} bytes, got {}",
                    chunk_index, config.chunk_size, bytes_read);
            }
            verification_errors += 1;
            continue;
        }

        total_bytes_read += bytes_read as u64;

        if &read_buffer[..bytes_read] != &expected_data[..] {
            if verification_errors < max_errors_to_report {
                println!("Error: Data mismatch at chunk {}", chunk_index);

                for byte_index in 0..config.chunk_size {
                    if read_buffer[byte_index] != expected_data[byte_index] {
                        println!("  First difference at byte {}: expected 0x{:02X}, got 0x{:02X}",
                            byte_index, expected_data[byte_index], read_buffer[byte_index]);
                        break;
                    }
                }
            }
            verification_errors += 1;
        }

        if (chunk_index + 1) % 1000 == 0 || chunk_index == number_of_chunks - 1 {
            let progress = (chunk_index + 1) as f64 / number_of_chunks as f64 * 100.0;
            println!("Verification progress: {:.1}% - Chunk {}/{}",
                progress, chunk_index + 1, number_of_chunks);
        }
    }

    let verification_end_time = Instant::now();
    let total_verification_time = verification_end_time.duration_since(verification_start_time).as_secs_f64();
    let read_speed_mbps = (total_bytes_read as f64 / (1024.0 * 1024.0)) / total_verification_time;

    if verification_errors == 0 {
        println!("Data verification completed successfully.");
        println!("Read speed during verification: {:.2} MB/s", read_speed_mbps);
        Ok((true, read_speed_mbps))
    } else {
        println!("Data verification failed - {} chunk(s) had errors", verification_errors);
        if verification_errors > max_errors_to_report {
            println!("   (Only first {} errors reported)", max_errors_to_report);
        }
        println!("Read speed during verification: {:.2} MB/s", read_speed_mbps);
        Ok((false, read_speed_mbps))
    }
}

fn run_test(config: Opt) -> IoResult<()> {
    setup_signal_handler();

    println!("Starting SSD write speed test...");
    println!("Target directory: {}", config.target.display());
    println!("Size ratio: {:.1}%", config.ratio * 100.0);
    println!("Chunk size: {} bytes", config.chunk_size);
    println!("Data verification: {}", if config.verify { "enabled" } else { "disabled" });
    println!("Output file: {}", config.csv.display());

    let available_space = get_available_space(&config.target)?;
    let total_bytes_to_write = (available_space as f64 * config.ratio) as u64;
    let number_of_chunks = (total_bytes_to_write / config.chunk_size as u64) as usize;

    println!("Available space: {} bytes", available_space);
    println!("Total bytes to write: {} bytes", total_bytes_to_write);
    println!("Number of chunks: {}", number_of_chunks);

    let mut random_generator = RandomGenerator::new(config.chunk_size, None);
    let mut original_chunks: Vec<Vec<u8>> = Vec::new();

    let mut test_file_path = config.target.clone();
    test_file_path.push("test.tmp");

    unsafe {
        TEST_FILE_PATH = Some(test_file_path.to_string_lossy().to_string());
    }

    let mut file = open_file_for_direct_write(&test_file_path, config.verify)?;

    let mut csv_lines = vec![
        "interval_number,operation_type,total_bytes_processed,interval_time_ms,speed_mbps".to_string()
    ];

    let mut total_bytes_written = 0u64;
    let test_start_time = Instant::now();
    let mut last_recorded_bytes = 0u64;
    let mut last_recorded_time = test_start_time;
    let mut interval_number = 1;

    println!("Starting write test...");

    for chunk_number in 0..number_of_chunks {
        if SIGNAL_RECEIVED.load(Ordering::Relaxed) {
            println!("\nStopping test due to interrupt signal...");
            break;
        }

        if config.verify {
            random_generator.fill_buffer(Some(chunk_number as u64));
        } else {
            random_generator.fill_buffer(None);
        }
        let chunk_data = random_generator.get_data();

        if config.verify {
            original_chunks.push(chunk_data.to_vec());
        }

        write_chunk_with_sync(&mut file, chunk_data)?;

        let chunk_end_time = Instant::now();
        total_bytes_written += config.chunk_size as u64;

        if total_bytes_written - last_recorded_bytes >= config.chunk_size as u64 {
            let interval_time = chunk_end_time.duration_since(last_recorded_time).as_millis() as f64;
            let interval_bytes = total_bytes_written - last_recorded_bytes;
            let interval_speed_mbps = (interval_bytes as f64 / (1024.0 * 1024.0)) /
                (chunk_end_time.duration_since(last_recorded_time).as_secs_f64());

            csv_lines.push(format!("{},write,{},{:.3},{:.2}",
                interval_number, total_bytes_written, interval_time, interval_speed_mbps));

            let progress = total_bytes_written as f64 / total_bytes_to_write as f64 * 100.0;
            let gb_written = total_bytes_written as f64 / (1024.0 * 1024.0 * 1024.0);

            // More detailed progress reporting
            if interval_speed_mbps < 100.0 {
                println!("Progress: {:.1}% - Interval {} - Write Speed: {:.2} MB/s - {:.2} GB written ⚠️  SLOW",
                    progress, interval_number, interval_speed_mbps, gb_written);
            } else if interval_speed_mbps < 300.0 {
                println!("Progress: {:.1}% - Interval {} - Write Speed: {:.2} MB/s - {:.2} GB written ⚡ MEDIUM",
                    progress, interval_number, interval_speed_mbps, gb_written);
            } else {
                println!("Progress: {:.1}% - Interval {} - Write Speed: {:.2} MB/s - {:.2} GB written 🚀 FAST",
                    progress, interval_number, interval_speed_mbps, gb_written);
            }

            last_recorded_bytes = total_bytes_written;
            last_recorded_time = chunk_end_time;
            interval_number += 1;
        }
    }

    let test_end_time = Instant::now();
    let total_test_time = test_end_time.duration_since(test_start_time).as_secs_f64();

    if total_bytes_written > last_recorded_bytes {
        let interval_time = test_end_time.duration_since(last_recorded_time).as_millis() as f64;
        let interval_bytes = total_bytes_written - last_recorded_bytes;
        let interval_speed_mbps = (interval_bytes as f64 / (1024.0 * 1024.0)) /
            (test_end_time.duration_since(last_recorded_time).as_secs_f64());
        csv_lines.push(format!("{},write,{},{:.3},{:.2}",
            interval_number, total_bytes_written, interval_time, interval_speed_mbps));
    }

    let average_write_speed = (total_bytes_written as f64 / (1024.0 * 1024.0)) / total_test_time;

    println!("\nWrite test completed!");
    println!("Total bytes written: {} bytes", total_bytes_written);
    println!("Total write time: {:.2} seconds", total_test_time);
    println!("Average write speed: {:.2} MB/s", average_write_speed);

    file.sync_all()?;

    let mut verification_success = true;
    let mut average_read_speed = 0.0;

    if config.verify && !SIGNAL_RECEIVED.load(Ordering::Relaxed) {
        match verify_written_data(&mut file, &config, number_of_chunks, &original_chunks) {
            Ok((success, read_speed)) => {
                verification_success = success;
                average_read_speed = read_speed;

                if success {
                    csv_lines.push(format!("{},read,{},{:.3},{:.2}",
                        interval_number + 1, total_bytes_written, total_test_time * 1000.0, read_speed));
                }
            }
            Err(e) => {
                println!("Error during verification: {}", e);
                verification_success = false;
            }
        }
    }

    drop(file);
    let _ = remove_file(&test_file_path);
    unsafe {
        TEST_FILE_PATH = None;
    }

    let csv_content = csv_lines.join("\n");
    std::fs::write(&config.csv, csv_content)?;
    println!("Results saved to: {}", config.csv.display());

    if SIGNAL_RECEIVED.load(Ordering::Relaxed) {
        println!("\nTest was interrupted by user");
        println!("Partial results written to: {}", config.csv.display());
    } else if config.verify {
        if verification_success {
            println!("\nTest completed successfully.");
            println!("Write Speed: {:.2} MB/s", average_write_speed);
            println!("Read Speed: {:.2} MB/s", average_read_speed);
        } else {
            println!("\nTest completed but data verification failed.");
        }
    } else {
        println!("\nTest completed successfully.");
        println!("Average Write Speed: {:.2} MB/s", average_write_speed);
    }

    Ok(())
}

fn main() {
    let config = Opt::parse();

    if config.ratio <= 0.0 || config.ratio > 1.0 {
        eprintln!("Error: Ratio must be between 0.0 and 1.0");
        process::exit(1);
    }

    if config.chunk_size == 0 {
        eprintln!("Error: Chunk size must be greater than 0");
        process::exit(1);
    }

    if let Err(e) = run_test(config) {
        eprintln!("Error: {}", e);
        process::exit(1);
    }
}