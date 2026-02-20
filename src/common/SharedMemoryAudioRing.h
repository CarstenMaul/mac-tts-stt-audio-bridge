#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

namespace bridge {

class SharedMemoryAudioRing {
 public:
  SharedMemoryAudioRing();
  ~SharedMemoryAudioRing();

  SharedMemoryAudioRing(const SharedMemoryAudioRing&) = delete;
  SharedMemoryAudioRing& operator=(const SharedMemoryAudioRing&) = delete;

  bool Open(const std::string& name, bool create, uint32_t channels, uint32_t capacity_frames);
  void Close();

  size_t Write(const float* interleaved_frames, size_t frame_count);
  size_t Read(float* interleaved_frames, size_t frame_count);

  uint32_t channels() const;
  uint32_t capacity_frames() const;
  bool is_open() const;

 private:
  struct Header {
    uint32_t magic;
    uint32_t version;
    uint32_t channels;
    uint32_t capacity_frames;
    std::atomic<uint32_t> write_index;
    std::atomic<uint32_t> read_index;
  };

  static constexpr uint32_t kMagic = 0x53415242;  // "SARB"
  static constexpr uint32_t kVersion = 1;

  size_t MappingSize(uint32_t channels, uint32_t capacity_frames) const;
  float* DataStart() const;
  bool InitializeIfNeeded(bool create, uint32_t channels, uint32_t capacity_frames);

  int shm_fd_;
  void* mapping_;
  size_t mapping_size_;
  Header* header_;
  std::string name_;
};

}  // namespace bridge
