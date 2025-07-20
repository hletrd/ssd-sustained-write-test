import Foundation
import Darwin
import Dispatch

var testFilePath: String?
var fileDescriptor: Int32?
var signalReceived = false

struct WriteSpeedTest {
  let targetDirectory: String
  let sizeRatio: Double
  let chunkSize: Int
  let outputFile: String
  let verify: Bool

  init(targetDirectory: String = ".",
       sizeRatio: Double = 1.0,
       chunkSize: Int = 10 * 1024 * 1024,
       outputFile: String = "result.csv",
       verify: Bool = false) {
    self.targetDirectory = targetDirectory
    self.sizeRatio = sizeRatio
    self.chunkSize = chunkSize
    self.outputFile = outputFile
    self.verify = verify
  }
}

class RandomGenerator {
  private var buffer: UnsafeMutableRawPointer
  private let bufferSize: Int
  private var seed: UInt32

  init(bufferSize: Int, seed: UInt32 = 0) {
    self.bufferSize = bufferSize
    self.seed = seed
    self.buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: MemoryLayout<UInt32>.alignment)
  }

  deinit {
    buffer.deallocate()
  }

  func fillBuffer(withSeed newSeed: UInt32? = nil) {
    if let newSeed = newSeed {
      self.seed = newSeed
    }

    if seed == 0 {
      arc4random_buf(buffer, bufferSize)
    } else {
      var currentSeed = seed
      let uint32Buffer = buffer.bindMemory(to: UInt32.self, capacity: bufferSize / 4)

      for i in 0..<(bufferSize / 4) {
        currentSeed = currentSeed.multipliedReportingOverflow(by: 1664525).partialValue.addingReportingOverflow(1013904223).partialValue
        uint32Buffer[i] = currentSeed
      }

      let remainingBytes = bufferSize % 4
      if remainingBytes > 0 {
        let byteBuffer = buffer.bindMemory(to: UInt8.self, capacity: bufferSize)
        currentSeed = currentSeed.multipliedReportingOverflow(by: 1664525).partialValue.addingReportingOverflow(1013904223).partialValue
        for i in 0..<remainingBytes {
          byteBuffer[bufferSize - remainingBytes + i] = UInt8((currentSeed >> (i * 8)) & 0xFF)
        }
      }
    }
  }

  func getData() -> Data {
    return Data(bytes: buffer, count: bufferSize)
  }
}

func getAvailableSpace(at path: String) -> UInt64? {
  let fileManager = FileManager.default
  do {
    let attributes = try fileManager.attributesOfFileSystem(forPath: path)
    if let freeSpace = attributes[.systemFreeSize] as? NSNumber {
      return freeSpace.uint64Value
    }
  } catch {
    print("Error getting disk space: \(error)")
  }
  return nil
}

func openFileForDirectWrite(path: String, verify: Bool = false) -> Int32? {
  let flags = verify ? (O_RDWR | O_CREAT | O_TRUNC | O_SYNC) : (O_WRONLY | O_CREAT | O_TRUNC | O_SYNC)
  let fd = open(path, flags, 0644)
  if fd == -1 {
    print("Error opening file: \(String(cString: strerror(errno)))")
    return nil
  }

  if fcntl(fd, F_NOCACHE, 1) == -1 {
    print("Warning: Could not enable F_NOCACHE: \(String(cString: strerror(errno)))")
  }

  return fd
}

func signalHandler(_ signal: Int32) {
  if signalReceived {
    print("\nTerminating immediately.")
    exit(1)
  }

  signalReceived = true
  print("\nReceived interrupt signal. Cleaning up test file...")
  print("Press Ctrl+C again to force immediate termination.")

  if let fd = fileDescriptor {
    close(fd)
  }

  if let filePath = testFilePath {
    unlink(filePath)
    print("Test file cleaned up.")
  }

  DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    exit(0)
  }
}

func writeChunk(fd: Int32, data: Data) -> Bool {
  let bytesWritten = data.withUnsafeBytes { bytes in
    write(fd, bytes.baseAddress, data.count)
  }

  if bytesWritten != data.count {
    print("Error writing chunk: \(String(cString: strerror(errno)))")
    return false
  }

  if fsync(fd) == -1 {
    print("Warning: fsync failed: \(String(cString: strerror(errno)))")
  }

  return true
}

func verifyWrittenData(fd: Int32, config: WriteSpeedTest, numberOfChunks: Int, originalChunks: [Data]) -> (Bool, Double) {
  print("\nStarting data verification...")

  if lseek(fd, 0, SEEK_SET) == -1 {
    print("Error: Could not seek to beginning of file: \(String(cString: strerror(errno)))")
    return (false, 0.0)
  }

  var readBuffer = Data(count: config.chunkSize)
  var verificationErrors = 0
  let maxErrorsToReport = 10
  var totalBytesRead: UInt64 = 0

  let verificationStartTime = CFAbsoluteTimeGetCurrent()

  print("Verifying \(numberOfChunks) chunks...")

  for chunkIndex in 0..<numberOfChunks {
    let expectedData = originalChunks[chunkIndex]

    let bytesRead = readBuffer.withUnsafeMutableBytes { bytes in
      read(fd, bytes.baseAddress, config.chunkSize)
    }

    if bytesRead != config.chunkSize {
      if verificationErrors < maxErrorsToReport {
        print("Error: Read mismatch at chunk \(chunkIndex) - expected \(config.chunkSize) bytes, got \(bytesRead)")
      }
      verificationErrors += 1
      continue
    }

    totalBytesRead += UInt64(bytesRead)

    if readBuffer != expectedData {
      if verificationErrors < maxErrorsToReport {
        print("Error: Data mismatch at chunk \(chunkIndex)")

        for byteIndex in 0..<config.chunkSize {
          if readBuffer[byteIndex] != expectedData[byteIndex] {
            print("  First difference at byte \(byteIndex): expected 0x\(String(format: "%02X", expectedData[byteIndex])), got 0x\(String(format: "%02X", readBuffer[byteIndex]))")
            break
          }
        }
      }
      verificationErrors += 1
    }

    if (chunkIndex + 1) % 1000 == 0 || chunkIndex == numberOfChunks - 1 {
      let progress = Double(chunkIndex + 1) / Double(numberOfChunks) * 100
      print("Verification progress: \(String(format: "%.1f", progress))% - Chunk \(chunkIndex + 1)/\(numberOfChunks)")
    }
  }

  let verificationEndTime = CFAbsoluteTimeGetCurrent()
  let totalVerificationTime = verificationEndTime - verificationStartTime
  let readSpeedMBps = (Double(totalBytesRead) / (1024 * 1024)) / totalVerificationTime

  if verificationErrors == 0 {
    print("Data verification completed.")
    print("Read speed during verification: \(String(format: "%.2f", readSpeedMBps)) MB/s")
    return (true, readSpeedMBps)
  } else {
    print("Data verification failed - \(verificationErrors) chunk(s) had errors")
    if verificationErrors > maxErrorsToReport {
      print("   (Only first \(maxErrorsToReport) errors reported)")
    }
    print("Read speed during verification: \(String(format: "%.2f", readSpeedMBps)) MB/s")
    return (false, readSpeedMBps)
  }
}

func runTest(config: WriteSpeedTest) {
  signal(SIGINT, signalHandler)
  signal(SIGTERM, signalHandler)

  print("Starting SSD write speed test...")
  print("Target directory: \(config.targetDirectory)")
  print("Size ratio: \(config.sizeRatio * 100)%")
  print("Chunk size: \(config.chunkSize) bytes")
  print("Data verification: \(config.verify ? "enabled" : "disabled")")
  print("Output file: \(config.outputFile)")

  guard let availableSpace = getAvailableSpace(at: config.targetDirectory) else {
    print("Failed to get available disk space")
    return
  }

  let totalBytesToWrite = UInt64(Double(availableSpace) * config.sizeRatio)
  let numberOfChunks = Int(totalBytesToWrite / UInt64(config.chunkSize))

  print("Available space: \(availableSpace) bytes")
  print("Total bytes to write: \(totalBytesToWrite) bytes")
  print("Number of chunks: \(numberOfChunks)")

  let randomGenerator = RandomGenerator(bufferSize: config.chunkSize)
  var originalChunks: [Data] = []

  let currentTestFilePath = "\(config.targetDirectory)/test.tmp"
  guard let fd = openFileForDirectWrite(path: currentTestFilePath, verify: config.verify) else {
    return
  }

  testFilePath = currentTestFilePath
  fileDescriptor = fd

  var csvLines: [String] = ["interval_number,operation_type,total_bytes_processed,interval_time_ms,speed_mbps"]

  var totalBytesWritten: UInt64 = 0
  let testStartTime = CFAbsoluteTimeGetCurrent()
  var lastRecordedBytes: UInt64 = 0
  var lastRecordedTime = testStartTime
  var intervalNumber = 1

  print("Starting write test...")

  for chunkNumber in 0..<numberOfChunks {
    if signalReceived {
      print("\nStopping test due to interrupt signal...")
      break
    }

    if config.verify {
      randomGenerator.fillBuffer(withSeed: UInt32(chunkNumber))
    } else {
      randomGenerator.fillBuffer()
    }
    let chunkData = randomGenerator.getData()

    if config.verify {
      originalChunks.append(chunkData)
    }

    if !writeChunk(fd: fd, data: chunkData) {
      print("Failed to write chunk \(chunkNumber)")
      break
    }

    let chunkEndTime = CFAbsoluteTimeGetCurrent()
    totalBytesWritten += UInt64(config.chunkSize)

    if totalBytesWritten - lastRecordedBytes >= UInt64(config.chunkSize) {
      let intervalTime = (chunkEndTime - lastRecordedTime) * 1000
      let intervalBytes = totalBytesWritten - lastRecordedBytes
      let intervalSpeedMBps = (Double(intervalBytes) / (1024 * 1024)) / (chunkEndTime - lastRecordedTime)

      csvLines.append("\(intervalNumber),write,\(totalBytesWritten),\(String(format: "%.3f", intervalTime)),\(String(format: "%.2f", intervalSpeedMBps))")

      let progress = Double(totalBytesWritten) / Double(totalBytesToWrite) * 100
      print("Progress: \(String(format: "%.1f", progress))% - Interval \(intervalNumber) - Write Speed: \(String(format: "%.2f", intervalSpeedMBps)) MB/s")

      lastRecordedBytes = totalBytesWritten
      lastRecordedTime = chunkEndTime
      intervalNumber += 1
    }
  }

  let testEndTime = CFAbsoluteTimeGetCurrent()
  let totalTestTime = testEndTime - testStartTime

  if totalBytesWritten > lastRecordedBytes {
    let intervalTime = (testEndTime - lastRecordedTime) * 1000
    let intervalBytes = totalBytesWritten - lastRecordedBytes
    let intervalSpeedMBps = (Double(intervalBytes) / (1024 * 1024)) / (testEndTime - lastRecordedTime)
    csvLines.append("\(intervalNumber),write,\(totalBytesWritten),\(String(format: "%.3f", intervalTime)),\(String(format: "%.2f", intervalSpeedMBps))")
  }

  let averageWriteSpeed = (Double(totalBytesWritten) / (1024 * 1024)) / totalTestTime

  print("\nWrite test completed!")
  print("Total bytes written: \(totalBytesWritten) bytes")
  print("Total write time: \(String(format: "%.2f", totalTestTime)) seconds")
  print("Average write speed: \(String(format: "%.2f", averageWriteSpeed)) MB/s")

  _ = fcntl(fd, F_FULLFSYNC)

  var verificationSuccess = true
  var averageReadSpeed: Double = 0.0

    if config.verify && !signalReceived {
    let (success, readSpeed) = verifyWrittenData(fd: fd, config: config, numberOfChunks: numberOfChunks, originalChunks: originalChunks)
    verificationSuccess = success
    averageReadSpeed = readSpeed

    if success {
      csvLines.append("\(intervalNumber + 1),read,\(totalBytesWritten),\(String(format: "%.3f", totalTestTime * 1000)),\(String(format: "%.2f", readSpeed))")
    }
  }

  fileDescriptor = nil
  testFilePath = nil
  close(fd)
  unlink(currentTestFilePath)

  let csvContent = csvLines.joined(separator: "\n")
  do {
    try csvContent.write(toFile: config.outputFile, atomically: true, encoding: .utf8)
    print("Results saved to: \(config.outputFile)")
  } catch {
    print("Error saving CSV file: \(error)")
  }

  if signalReceived {
    print("\nTest was interrupted by user")
    print("Partial results written to: \(config.outputFile)")
  } else if config.verify {
    if verificationSuccess {
      print("\nTest completed.")
      print("Write Speed: \(String(format: "%.2f", averageWriteSpeed)) MB/s")
      print("Read Speed: \(String(format: "%.2f", averageReadSpeed)) MB/s")
    } else {
      print("\nTest completed but data verification failed.")
    }
  } else {
    print("\nTest completed.")
    print("Write Speed: \(String(format: "%.2f", averageWriteSpeed)) MB/s")
  }
}

func printUsage() {
  print("Usage: ssd_write_test [options]")
  print("Options:")
  print("  -d, --directory <path>     Target directory (default: current directory)")
  print("  -r, --ratio <0.0-1.0>      Size ratio of available space to use (default: 1.0)")
  print("  -c, --chunk-size <bytes>   Chunk size in bytes (default: 10MiB)")
  print("  -o, --output <file>        Output CSV file (default: result.csv)")
  print("  -v, --verify               Verify data after write (default: disabled)")
  print("  -h, --help                 Show this help message")
}

func parseArguments() -> WriteSpeedTest? {
  let args = CommandLine.arguments
  var targetDirectory = "."
  var sizeRatio = 1.0
  var chunkSize = 10 * 1024 * 1024
  var outputFile = "result.csv"
  var verify = false

  var i = 1
  while i < args.count {
    let arg = args[i]

    switch arg {
    case "-h", "--help":
      printUsage()
      return nil
    case "-d", "--directory":
      if i + 1 < args.count {
        targetDirectory = args[i + 1]
        i += 1
      } else {
        print("Error: Missing value for \(arg)")
        return nil
      }
    case "-r", "--ratio":
      if i + 1 < args.count {
        if let ratio = Double(args[i + 1]), ratio > 0.0 && ratio <= 1.0 {
          sizeRatio = ratio
          i += 1
        } else {
          print("Error: Invalid ratio value. Must be between 0.0 and 1.0")
          return nil
        }
      } else {
        print("Error: Missing value for \(arg)")
        return nil
      }
    case "-c", "--chunk-size":
      if i + 1 < args.count {
        if let size = Int(args[i + 1]), size > 0 {
          chunkSize = size
          i += 1
        } else {
          print("Error: Invalid chunk size. Must be a positive integer")
          return nil
        }
      } else {
        print("Error: Missing value for \(arg)")
        return nil
      }
    case "-o", "--output":
      if i + 1 < args.count {
        outputFile = args[i + 1]
        i += 1
      } else {
        print("Error: Missing value for \(arg)")
        return nil
      }
    case "-v", "--verify":
      verify = true
    default:
      print("Error: Unknown argument \(arg)")
      printUsage()
      return nil
    }

    i += 1
  }

  return WriteSpeedTest(
    targetDirectory: targetDirectory,
    sizeRatio: sizeRatio,
    chunkSize: chunkSize,
    outputFile: outputFile,
    verify: verify
  )
}

if let config = parseArguments() {
  runTest(config: config)
} else {
  exit(1)
}