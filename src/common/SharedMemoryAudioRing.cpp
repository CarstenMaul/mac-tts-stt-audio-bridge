#include "SharedMemoryAudioRing.h"

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace bridge {

namespace {

uint32_t MinU32(uint32_t a, uint32_t b) {
  return a < b ? a : b;
}

size_t MinSizeT(size_t a, size_t b) {
  return a < b ? a : b;
}

}  // namespace

SharedMemoryAudioRing::SharedMemoryAudioRing()
    : shm_fd_(-1), mapping_(nullptr), mapping_size_(0), header_(nullptr) {}

SharedMemoryAudioRing::~SharedMemoryAudioRing() {
  Close();
}

size_t SharedMemoryAudioRing::MappingSize(uint32_t channels, uint32_t capacity_frames) const {
  return sizeof(Header) + (sizeof(float) * static_cast<size_t>(channels) *
                           static_cast<size_t>(capacity_frames));
}

float* SharedMemoryAudioRing::DataStart() const {
  return reinterpret_cast<float*>(reinterpret_cast<uint8_t*>(mapping_) + sizeof(Header));
}

bool SharedMemoryAudioRing::InitializeIfNeeded(bool create,
                                               uint32_t channels,
                                               uint32_t capacity_frames) {
  if (header_ == nullptr) {
    return false;
  }

  if (create ||
      header_->magic != kMagic ||
      header_->version != kVersion ||
      header_->channels != channels ||
      header_->capacity_frames != capacity_frames) {
    std::memset(mapping_, 0, mapping_size_);
    header_->magic = kMagic;
    header_->version = kVersion;
    header_->channels = channels;
    header_->capacity_frames = capacity_frames;
    header_->write_index.store(0, std::memory_order_relaxed);
    header_->read_index.store(0, std::memory_order_relaxed);
  }

  return true;
}

bool SharedMemoryAudioRing::Open(const std::string& name,
                                 bool create,
                                 uint32_t channels,
                                 uint32_t capacity_frames) {
  Close();

  if (name.empty() || channels == 0 || capacity_frames == 0) {
    return false;
  }

  std::string path_name = name;
  if (!path_name.empty() && path_name[0] == '/') {
    path_name.erase(0, 1);
  }
  std::replace(path_name.begin(), path_name.end(), '/', '_');
  const std::string backing_file = "/tmp/" + path_name + ".ring";

  const int flags = create ? (O_CREAT | O_RDWR) : O_RDWR;
  shm_fd_ = open(backing_file.c_str(), flags, 0666);
  if (shm_fd_ < 0) {
    return false;
  }
  // Force permissions regardless of umask so both the driver (_coreaudiod)
  // and user-space helper can read and write the ring.
  (void)fchmod(shm_fd_, 0666);

  mapping_size_ = MappingSize(channels, capacity_frames);
  if (ftruncate(shm_fd_, static_cast<off_t>(mapping_size_)) != 0) {
    Close();
    return false;
  }

  mapping_ = mmap(nullptr, mapping_size_, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd_, 0);
  if (mapping_ == MAP_FAILED) {
    mapping_ = nullptr;
    Close();
    return false;
  }

  header_ = reinterpret_cast<Header*>(mapping_);
  if (!InitializeIfNeeded(create, channels, capacity_frames)) {
    Close();
    return false;
  }

  name_ = backing_file;
  return true;
}

void SharedMemoryAudioRing::Close() {
  if (mapping_ != nullptr) {
    munmap(mapping_, mapping_size_);
    mapping_ = nullptr;
  }
  if (shm_fd_ >= 0) {
    close(shm_fd_);
    shm_fd_ = -1;
  }
  mapping_size_ = 0;
  header_ = nullptr;
  name_.clear();
}

size_t SharedMemoryAudioRing::Write(const float* interleaved_frames, size_t frame_count) {
  if (header_ == nullptr || interleaved_frames == nullptr || frame_count == 0) {
    return 0;
  }

  const uint32_t channels = header_->channels;
  const uint32_t capacity = header_->capacity_frames;
  uint32_t write = header_->write_index.load(std::memory_order_acquire);
  uint32_t read = header_->read_index.load(std::memory_order_acquire);
  const uint32_t used = write - read;
  const uint32_t free_frames = capacity - MinU32(used, capacity);
  const uint32_t to_write = static_cast<uint32_t>(MinSizeT(frame_count, free_frames));
  if (to_write == 0) {
    return 0;
  }

  float* data = DataStart();
  for (uint32_t frame = 0; frame < to_write; ++frame) {
    const uint32_t dst_frame = (write + frame) % capacity;
    const size_t src_idx = static_cast<size_t>(frame) * channels;
    const size_t dst_idx = static_cast<size_t>(dst_frame) * channels;
    std::memcpy(&data[dst_idx], &interleaved_frames[src_idx], sizeof(float) * channels);
  }

  header_->write_index.store(write + to_write, std::memory_order_release);
  return to_write;
}

size_t SharedMemoryAudioRing::Read(float* interleaved_frames, size_t frame_count) {
  if (header_ == nullptr || interleaved_frames == nullptr || frame_count == 0) {
    return 0;
  }

  const uint32_t channels = header_->channels;
  const uint32_t capacity = header_->capacity_frames;
  uint32_t write = header_->write_index.load(std::memory_order_acquire);
  uint32_t read = header_->read_index.load(std::memory_order_acquire);
  const uint32_t available = MinU32(write - read, capacity);
  const uint32_t to_read = static_cast<uint32_t>(MinSizeT(frame_count, available));
  if (to_read == 0) {
    return 0;
  }

  float* data = DataStart();
  for (uint32_t frame = 0; frame < to_read; ++frame) {
    const uint32_t src_frame = (read + frame) % capacity;
    const size_t src_idx = static_cast<size_t>(src_frame) * channels;
    const size_t dst_idx = static_cast<size_t>(frame) * channels;
    std::memcpy(&interleaved_frames[dst_idx], &data[src_idx], sizeof(float) * channels);
  }

  header_->read_index.store(read + to_read, std::memory_order_release);
  return to_read;
}

uint32_t SharedMemoryAudioRing::channels() const {
  return header_ == nullptr ? 0 : header_->channels;
}

uint32_t SharedMemoryAudioRing::capacity_frames() const {
  return header_ == nullptr ? 0 : header_->capacity_frames;
}

bool SharedMemoryAudioRing::is_open() const {
  return header_ != nullptr;
}

}  // namespace bridge
