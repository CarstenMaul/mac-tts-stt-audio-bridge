#include "SharedMemoryAudioRing.h"

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <arpa/inet.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <functional>
#include <iostream>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr uint32_t kChannels = 2;
constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kChunkFrames = 480;
constexpr uint32_t kRingCapacityFrames = 48000;
constexpr const char* kMicFeedName = "/virtual_audio_bridge_mic_feed";
constexpr const char* kSpeakerTapName = "/virtual_audio_bridge_speaker_tap";
constexpr const char* kProtocolVersion = "1";

std::atomic<bool> g_should_exit{false};
bool g_verbose = false;

#define VLOG(msg)          \
  do {                     \
    if (g_verbose) {       \
      std::cerr << "[verbose] " << msg << "\n"; \
    }                      \
  } while (0)

void SignalHandler(int /*sig*/) {
  g_should_exit.store(true, std::memory_order_relaxed);
}

std::string NSStringToStdString(NSString* value) {
  if (value == nil) {
    return "";
  }
  const char* cstr = [value UTF8String];
  return cstr == nullptr ? "" : std::string(cstr);
}

NSString* StdStringToNSString(const std::string& value) {
  return [NSString stringWithUTF8String:value.c_str()];
}

std::string ToLower(std::string value) {
  std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return value;
}

std::string Trim(std::string s) {
  auto not_space = [](unsigned char c) { return !std::isspace(c); };
  s.erase(s.begin(), std::find_if(s.begin(), s.end(), not_space));
  s.erase(std::find_if(s.rbegin(), s.rend(), not_space).base(), s.end());
  return s;
}

std::string ExecutableDir() {
  uint32_t size = 0;
  _NSGetExecutablePath(nullptr, &size);
  std::string path(size, '\0');
  if (_NSGetExecutablePath(path.data(), &size) != 0) {
    return ".";
  }
  path.resize(std::strlen(path.c_str()));
  const auto pos = path.find_last_of('/');
  if (pos == std::string::npos) {
    return ".";
  }
  return path.substr(0, pos);
}

bool FileIsExecutable(const std::string& path) {
  return access(path.c_str(), X_OK) == 0;
}

NSDictionary* ParseJsonObject(const std::string& text, std::string* error) {
  NSData* data = [NSData dataWithBytes:text.data() length:text.size()];
  NSError* ns_error = nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&ns_error];
  if (ns_error != nil || ![obj isKindOfClass:[NSDictionary class]]) {
    if (error != nullptr) {
      *error = ns_error == nil ? "JSON payload is not an object" : NSStringToStdString(ns_error.localizedDescription);
    }
    return nil;
  }
  return (NSDictionary*)obj;
}

std::string SerializeJsonObject(NSDictionary* obj, std::string* error) {
  @autoreleasepool {
    NSError* ns_error = nil;
    NSData* data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&ns_error];
    if (ns_error != nil || data == nil) {
      if (error != nullptr) {
        *error = ns_error == nil ? "failed to serialize JSON" : NSStringToStdString(ns_error.localizedDescription);
      }
      return "";
    }
    return std::string(reinterpret_cast<const char*>(data.bytes), data.length);
  }
}

std::string BuildWebSocketAccept(const std::string& sec_websocket_key) {
  const std::string magic = sec_websocket_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
  unsigned char hash[CC_SHA1_DIGEST_LENGTH];
  CC_SHA1(magic.data(), static_cast<CC_LONG>(magic.size()), hash);
  @autoreleasepool {
    NSData* digest = [NSData dataWithBytes:hash length:CC_SHA1_DIGEST_LENGTH];
    NSString* base64 = [digest base64EncodedStringWithOptions:0];
    return NSStringToStdString(base64);
  }
}

bool ReadExactBuffered(int fd,
                      std::string* pending_bytes,
                      void* buffer,
                      size_t bytes,
                      int timeout_ms) {
  uint8_t* out = reinterpret_cast<uint8_t*>(buffer);
  size_t offset = 0;

  if (pending_bytes != nullptr && !pending_bytes->empty()) {
    const size_t take = std::min(bytes, pending_bytes->size());
    std::memcpy(out, pending_bytes->data(), take);
    pending_bytes->erase(0, take);
    offset += take;
  }

  while (offset < bytes) {
    struct pollfd pfd {};
    pfd.fd = fd;
    pfd.events = POLLIN;
    const int poll_result = poll(&pfd, 1, timeout_ms);
    if (poll_result <= 0) {
      return false;
    }
    if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      return false;
    }

    uint8_t chunk[4096];
    const ssize_t rc = recv(fd, chunk, sizeof(chunk), 0);
    if (rc <= 0) {
      return false;
    }
    const size_t got = static_cast<size_t>(rc);
    const size_t needed = bytes - offset;
    const size_t take = std::min(got, needed);
    std::memcpy(out + offset, chunk, take);
    offset += take;

    if (got > take && pending_bytes != nullptr) {
      pending_bytes->append(reinterpret_cast<const char*>(chunk + take), got - take);
    }
  }
  return true;
}

bool SendAll(int fd, const void* data, size_t size) {
  const uint8_t* ptr = reinterpret_cast<const uint8_t*>(data);
  size_t sent = 0;
  while (sent < size) {
    const ssize_t rc = write(fd, ptr + sent, size - sent);
    if (rc <= 0) {
      if (errno == EINTR) {
        continue;
      }
      return false;
    }
    sent += static_cast<size_t>(rc);
  }
  return true;
}

void CloseFd(int* fd) {
  if (*fd >= 0) {
    close(*fd);
    *fd = -1;
  }
}

struct SessionDefaults {
  std::string mode = "apple";
  std::string stt_source = "virtual_speaker";
  std::string tts_target = "virtual_mic";
};

struct AudioConfig {
  int sample_rate_hz = 48000;
  int channels = 2;
  int ring_capacity_frames = 48000;
};

struct ElevenLabsTtsConfig {
  std::string voice_id;
  std::string model_id = "eleven_flash_v2_5";
  std::string output_format = "pcm_48000";
};

struct ElevenLabsSttConfig {
  std::string model_id = "scribe_v2_realtime";
  std::string language_code = "en";
};

struct ElevenLabsConfig {
  std::string api_key_env = "ELEVENLABS_API_KEY";
  std::string api_key;
  ElevenLabsTtsConfig tts;
  ElevenLabsSttConfig stt;
};

struct AppleConfig {
  std::string locale = "en-US";
  bool on_device_only = true;
};

struct BridgeConfig {
  std::string host = "127.0.0.1";
  int port = 0;
  SessionDefaults session_defaults;
  AudioConfig audio;
  ElevenLabsConfig elevenlabs;
  AppleConfig apple;
  std::string helper_path;
};

std::optional<NSDictionary*> DictForKey(NSDictionary* dict, NSString* key) {
  id value = dict[key];
  if ([value isKindOfClass:[NSDictionary class]]) {
    return (NSDictionary*)value;
  }
  return std::nullopt;
}

std::optional<std::string> StringForKey(NSDictionary* dict, NSString* key) {
  id value = dict[key];
  if ([value isKindOfClass:[NSString class]]) {
    return NSStringToStdString((NSString*)value);
  }
  return std::nullopt;
}

std::optional<int> IntForKey(NSDictionary* dict, NSString* key) {
  id value = dict[key];
  if ([value isKindOfClass:[NSNumber class]]) {
    return [((NSNumber*)value) intValue];
  }
  return std::nullopt;
}

std::optional<bool> BoolForKey(NSDictionary* dict, NSString* key) {
  id value = dict[key];
  if ([value isKindOfClass:[NSNumber class]]) {
    return [((NSNumber*)value) boolValue];
  }
  return std::nullopt;
}

bool LoadConfig(const std::string& path, BridgeConfig* out_config, std::string* error) {
  if (out_config == nullptr) {
    if (error != nullptr) {
      *error = "internal error: null output config";
    }
    return false;
  }

  @autoreleasepool {
    NSString* ns_path = StdStringToNSString(path);
    NSData* data = [NSData dataWithContentsOfFile:ns_path];
    if (data == nil) {
      if (error != nullptr) {
        *error = "failed to read config file: " + path;
      }
      return false;
    }

    NSError* json_error = nil;
    id root_obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&json_error];
    if (json_error != nil || ![root_obj isKindOfClass:[NSDictionary class]]) {
      if (error != nullptr) {
        *error = json_error == nil ? "config root must be an object" : NSStringToStdString(json_error.localizedDescription);
      }
      return false;
    }

    NSDictionary* root = (NSDictionary*)root_obj;
    BridgeConfig cfg;

    if (auto websocket_dict_opt = DictForKey(root, @"websocket")) {
      NSDictionary* websocket_dict = *websocket_dict_opt;
      if (auto host = StringForKey(websocket_dict, @"host")) {
        cfg.host = *host;
      }
      if (auto port = IntForKey(websocket_dict, @"port")) {
        cfg.port = *port;
      }
    }

    if (cfg.port <= 0 || cfg.port > 65535) {
      if (error != nullptr) {
        *error = "websocket.port is required and must be between 1 and 65535";
      }
      return false;
    }

    if (auto defaults_dict_opt = DictForKey(root, @"session_defaults")) {
      NSDictionary* defaults_dict = *defaults_dict_opt;
      if (auto value = StringForKey(defaults_dict, @"mode")) {
        cfg.session_defaults.mode = *value;
      }
      if (auto value = StringForKey(defaults_dict, @"stt_source")) {
        cfg.session_defaults.stt_source = *value;
      }
      if (auto value = StringForKey(defaults_dict, @"tts_target")) {
        cfg.session_defaults.tts_target = *value;
      }
    }

    if (auto audio_dict_opt = DictForKey(root, @"audio")) {
      NSDictionary* audio_dict = *audio_dict_opt;
      if (auto value = IntForKey(audio_dict, @"sample_rate_hz")) {
        cfg.audio.sample_rate_hz = *value;
      }
      if (auto value = IntForKey(audio_dict, @"channels")) {
        cfg.audio.channels = *value;
      }
      if (auto value = IntForKey(audio_dict, @"ring_capacity_frames")) {
        cfg.audio.ring_capacity_frames = *value;
      }
    }

    if (auto eleven_dict_opt = DictForKey(root, @"elevenlabs")) {
      NSDictionary* eleven = *eleven_dict_opt;
      if (auto v = StringForKey(eleven, @"api_key_env")) {
        cfg.elevenlabs.api_key_env = *v;
      }

      if (auto tts_opt = DictForKey(eleven, @"tts")) {
        NSDictionary* tts = *tts_opt;
        if (auto v = StringForKey(tts, @"voice_id")) {
          cfg.elevenlabs.tts.voice_id = *v;
        }
        if (auto v = StringForKey(tts, @"model_id")) {
          cfg.elevenlabs.tts.model_id = *v;
        }
        if (auto v = StringForKey(tts, @"output_format")) {
          cfg.elevenlabs.tts.output_format = *v;
        }
      }

      if (auto stt_opt = DictForKey(eleven, @"stt")) {
        NSDictionary* stt = *stt_opt;
        if (auto v = StringForKey(stt, @"model_id")) {
          cfg.elevenlabs.stt.model_id = *v;
        }
        if (auto v = StringForKey(stt, @"language_code")) {
          cfg.elevenlabs.stt.language_code = *v;
        }
      }
    }

    if (auto apple_opt = DictForKey(root, @"apple")) {
      NSDictionary* apple = *apple_opt;
      if (auto v = StringForKey(apple, @"locale")) {
        cfg.apple.locale = *v;
      }
      if (auto v = BoolForKey(apple, @"on_device_only")) {
        cfg.apple.on_device_only = *v;
      }
    }

    if (auto helper_path = StringForKey(root, @"helper_path")) {
      cfg.helper_path = *helper_path;
    }

    if (cfg.helper_path.empty()) {
      cfg.helper_path = ExecutableDir() + "/engine_helper";
    }
    if (!cfg.helper_path.empty() && cfg.helper_path[0] != '/') {
      char cwd[PATH_MAX];
      if (getcwd(cwd, sizeof(cwd)) != nullptr) {
        cfg.helper_path = std::string(cwd) + "/" + cfg.helper_path;
      }
    }

    const char* api_key_env = std::getenv(cfg.elevenlabs.api_key_env.c_str());
    if (api_key_env != nullptr) {
      cfg.elevenlabs.api_key = api_key_env;
    }

    const std::string normalized_mode = ToLower(cfg.session_defaults.mode);
    if (normalized_mode != "apple" && normalized_mode != "elevenlabs") {
      if (error != nullptr) {
        *error = "session_defaults.mode must be apple or elevenlabs";
      }
      return false;
    }
    cfg.session_defaults.mode = normalized_mode;

    if (cfg.session_defaults.stt_source != "virtual_speaker" &&
        cfg.session_defaults.stt_source != "virtual_mic") {
      if (error != nullptr) {
        *error = "session_defaults.stt_source must be virtual_speaker or virtual_mic";
      }
      return false;
    }

    if (cfg.session_defaults.tts_target != "virtual_mic" &&
        cfg.session_defaults.tts_target != "virtual_speaker" &&
        cfg.session_defaults.tts_target != "both") {
      if (error != nullptr) {
        *error = "session_defaults.tts_target must be virtual_mic, virtual_speaker, or both";
      }
      return false;
    }

    *out_config = cfg;
    VLOG("Config loaded: ws://" << cfg.host << ":" << cfg.port
         << " mode=" << cfg.session_defaults.mode
         << " helper=" << cfg.helper_path);
    return true;
  }
}

class HelperProcess {
 public:
  using LineCallback = std::function<void(const std::string&)>;

  HelperProcess() = default;
  ~HelperProcess() {
    Stop();
  }

  bool Start(const std::string& path, LineCallback callback, std::string* error) {
    VLOG("HelperProcess::Start path=" << path);
    Stop();

    int stdin_pipe[2] = {-1, -1};
    int stdout_pipe[2] = {-1, -1};
    if (pipe(stdin_pipe) != 0 || pipe(stdout_pipe) != 0) {
      if (error != nullptr) {
        *error = "failed to create helper pipes";
      }
      CloseFd(&stdin_pipe[0]);
      CloseFd(&stdin_pipe[1]);
      CloseFd(&stdout_pipe[0]);
      CloseFd(&stdout_pipe[1]);
      return false;
    }

    pid_t child = fork();
    if (child < 0) {
      if (error != nullptr) {
        *error = "failed to fork helper process";
      }
      CloseFd(&stdin_pipe[0]);
      CloseFd(&stdin_pipe[1]);
      CloseFd(&stdout_pipe[0]);
      CloseFd(&stdout_pipe[1]);
      return false;
    }

    if (child == 0) {
      dup2(stdin_pipe[0], STDIN_FILENO);
      dup2(stdout_pipe[1], STDOUT_FILENO);
      dup2(stdout_pipe[1], STDERR_FILENO);

      CloseFd(&stdin_pipe[0]);
      CloseFd(&stdin_pipe[1]);
      CloseFd(&stdout_pipe[0]);
      CloseFd(&stdout_pipe[1]);

      execl(path.c_str(), path.c_str(), nullptr);
      _exit(127);
    }

    CloseFd(&stdin_pipe[0]);
    CloseFd(&stdout_pipe[1]);

    path_ = path;
    callback_ = std::move(callback);
    child_pid_ = child;
    stdin_fd_ = stdin_pipe[1];
    stdout_fd_ = stdout_pipe[0];
    running_.store(true, std::memory_order_relaxed);

    reader_thread_ = std::thread([this]() { ReaderLoop(); });
    waiter_thread_ = std::thread([this]() { WaiterLoop(); });

    VLOG("Helper process started, pid=" << child_pid_);
    return true;
  }

  void Stop() {
    const bool was_running = running_.exchange(false, std::memory_order_relaxed);

    if (was_running && stdin_fd_ >= 0) {
      std::string ignored;
      (void)SendLine("{\"type\":\"shutdown\"}", &ignored);
    }

    CloseFd(&stdin_fd_);
    CloseFd(&stdout_fd_);

    if (child_pid_ > 0 && was_running) {
      kill(child_pid_, SIGTERM);
      int status = 0;
      waitpid(child_pid_, &status, 0);
    }

    if (reader_thread_.joinable()) {
      reader_thread_.join();
    }
    if (waiter_thread_.joinable()) {
      waiter_thread_.join();
    }

    child_pid_ = -1;
    callback_ = nullptr;
  }

  bool SendLine(const std::string& line, std::string* error) {
    VLOG("Helper << " << line);
    std::lock_guard<std::mutex> lock(write_mutex_);
    if (!running_.load(std::memory_order_relaxed) || stdin_fd_ < 0) {
      if (error != nullptr) {
        *error = "helper is not running";
      }
      return false;
    }

    const std::string payload = line + "\n";
    if (!SendAll(stdin_fd_, payload.data(), payload.size())) {
      if (error != nullptr) {
        *error = "failed to write to helper stdin";
      }
      running_.store(false, std::memory_order_relaxed);
      return false;
    }

    return true;
  }

  bool IsRunning() const {
    return running_.load(std::memory_order_relaxed);
  }

  int ExitCode() const {
    return exit_code_.load(std::memory_order_relaxed);
  }

 private:
  void ReaderLoop() {
    FILE* stream = fdopen(stdout_fd_, "r");
    if (stream == nullptr) {
      running_.store(false, std::memory_order_relaxed);
      return;
    }

    char* line = nullptr;
    size_t capacity = 0;
    while (running_.load(std::memory_order_relaxed)) {
      const ssize_t read = getline(&line, &capacity, stream);
      if (read <= 0) {
        break;
      }
      std::string payload(line, static_cast<size_t>(read));
      while (!payload.empty() && (payload.back() == '\n' || payload.back() == '\r')) {
        payload.pop_back();
      }
      if (!payload.empty() && callback_ != nullptr) {
        VLOG("Helper >> " << payload);
        callback_(payload);
      }
    }

    if (line != nullptr) {
      free(line);
    }
    fclose(stream);
    running_.store(false, std::memory_order_relaxed);
  }

  void WaiterLoop() {
    if (child_pid_ <= 0) {
      return;
    }

    int status = 0;
    const pid_t rc = waitpid(child_pid_, &status, 0);
    if (rc > 0) {
      if (WIFEXITED(status)) {
        exit_code_.store(WEXITSTATUS(status), std::memory_order_relaxed);
      } else if (WIFSIGNALED(status)) {
        exit_code_.store(128 + WTERMSIG(status), std::memory_order_relaxed);
      }
      running_.store(false, std::memory_order_relaxed);
    }
  }

  std::string path_;
  LineCallback callback_;
  pid_t child_pid_ = -1;
  int stdin_fd_ = -1;
  int stdout_fd_ = -1;
  std::atomic<bool> running_{false};
  std::atomic<int> exit_code_{0};
  std::mutex write_mutex_;
  std::thread reader_thread_;
  std::thread waiter_thread_;
};

enum class WsOpcode : uint8_t {
  kContinuation = 0x0,
  kText = 0x1,
  kBinary = 0x2,
  kClose = 0x8,
  kPing = 0x9,
  kPong = 0xA,
};

struct WsFrame {
  WsOpcode opcode = WsOpcode::kText;
  bool fin = true;
  std::string payload;
};

bool PerformWebSocketHandshake(int fd, std::string* out_extra_bytes, std::string* error) {
  std::string request;
  request.reserve(2048);

  auto start = std::chrono::steady_clock::now();
  constexpr size_t kMaxRequestSize = 16384;

  while (request.find("\r\n\r\n") == std::string::npos) {
    const auto now = std::chrono::steady_clock::now();
    if (std::chrono::duration_cast<std::chrono::seconds>(now - start).count() > 5) {
      if (error != nullptr) {
        *error = "timeout waiting for websocket handshake";
      }
      return false;
    }

    char buf[1024];
    struct pollfd pfd {};
    pfd.fd = fd;
    pfd.events = POLLIN;
    const int pr = poll(&pfd, 1, 200);
    if (pr < 0) {
      if (error != nullptr) {
        *error = "poll failed while reading handshake";
      }
      return false;
    }
    if (pr == 0) {
      continue;
    }

    const ssize_t rc = recv(fd, buf, sizeof(buf), 0);
    if (rc <= 0) {
      if (error != nullptr) {
        *error = "connection closed during websocket handshake";
      }
      return false;
    }
    request.append(buf, static_cast<size_t>(rc));
    if (request.size() > kMaxRequestSize) {
      if (error != nullptr) {
        *error = "websocket handshake request too large";
      }
      return false;
    }
  }

  std::istringstream lines(request);
  std::string line;
  if (!std::getline(lines, line)) {
    if (error != nullptr) {
      *error = "malformed websocket handshake request";
    }
    return false;
  }

  if (line.find("GET") != 0) {
    if (error != nullptr) {
      *error = "websocket handshake must be GET";
    }
    return false;
  }

  std::unordered_map<std::string, std::string> headers;
  while (std::getline(lines, line)) {
    if (!line.empty() && line.back() == '\r') {
      line.pop_back();
    }
    if (line.empty()) {
      break;
    }
    const size_t colon = line.find(':');
    if (colon == std::string::npos) {
      continue;
    }
    std::string key = ToLower(Trim(line.substr(0, colon)));
    std::string value = Trim(line.substr(colon + 1));
    headers[key] = value;
  }

  auto key_it = headers.find("sec-websocket-key");
  if (key_it == headers.end()) {
    if (error != nullptr) {
      *error = "missing Sec-WebSocket-Key";
    }
    return false;
  }

  const std::string accept_value = BuildWebSocketAccept(key_it->second);
  std::ostringstream response;
  response << "HTTP/1.1 101 Switching Protocols\r\n"
           << "Upgrade: websocket\r\n"
           << "Connection: Upgrade\r\n"
           << "Sec-WebSocket-Accept: " << accept_value << "\r\n\r\n";

  const std::string response_data = response.str();
  VLOG("WebSocket handshake: sending 101 Switching Protocols");
  if (!SendAll(fd, response_data.data(), response_data.size())) {
    return false;
  }

  if (out_extra_bytes != nullptr) {
    const size_t header_end = request.find("\r\n\r\n");
    if (header_end != std::string::npos) {
      const size_t extra_offset = header_end + 4;
      if (extra_offset < request.size()) {
        *out_extra_bytes = request.substr(extra_offset);
      } else {
        out_extra_bytes->clear();
      }
    } else {
      out_extra_bytes->clear();
    }
  }

  return true;
}

void RejectHttpConnection(int fd, int status_code, const std::string& message) {
  std::ostringstream response;
  response << "HTTP/1.1 " << status_code << " Rejected\r\n"
           << "Content-Type: application/json\r\n"
           << "Connection: close\r\n\r\n"
           << "{\"error\":\"" << message << "\"}";
  const std::string payload = response.str();
  (void)SendAll(fd, payload.data(), payload.size());
  close(fd);
}

bool ReadWebSocketFrame(int fd,
                        std::string* pending_bytes,
                        WsFrame* out_frame,
                        int timeout_ms,
                        std::string* error) {
  uint8_t h1 = 0;
  uint8_t h2 = 0;
  if (!ReadExactBuffered(fd, pending_bytes, &h1, 1, timeout_ms) ||
      !ReadExactBuffered(fd, pending_bytes, &h2, 1, timeout_ms)) {
    if (error != nullptr) {
      *error = "failed to read websocket frame header";
    }
    return false;
  }

  const bool fin = (h1 & 0x80) != 0;
  const WsOpcode opcode = static_cast<WsOpcode>(h1 & 0x0F);
  const bool masked = (h2 & 0x80) != 0;
  uint64_t payload_len = h2 & 0x7F;

  if (payload_len == 126) {
    uint16_t ext = 0;
    if (!ReadExactBuffered(fd, pending_bytes, &ext, sizeof(ext), timeout_ms)) {
      if (error != nullptr) {
        *error = "failed to read extended websocket payload length (16-bit)";
      }
      return false;
    }
    payload_len = ntohs(ext);
  } else if (payload_len == 127) {
    uint64_t ext = 0;
    if (!ReadExactBuffered(fd, pending_bytes, &ext, sizeof(ext), timeout_ms)) {
      if (error != nullptr) {
        *error = "failed to read extended websocket payload length (64-bit)";
      }
      return false;
    }
    payload_len = OSSwapBigToHostInt64(ext);
  }

  uint8_t masking_key[4] = {0, 0, 0, 0};
  if (masked) {
    if (!ReadExactBuffered(fd, pending_bytes, masking_key, sizeof(masking_key), timeout_ms)) {
      if (error != nullptr) {
        *error = "failed to read websocket masking key";
      }
      return false;
    }
  }

  if (payload_len > (4 * 1024 * 1024)) {
    if (error != nullptr) {
      *error = "websocket payload too large";
    }
    return false;
  }

  std::string payload(payload_len, '\0');
  if (payload_len > 0 &&
      !ReadExactBuffered(fd, pending_bytes, payload.data(), payload_len, timeout_ms)) {
    if (error != nullptr) {
      *error = "failed to read websocket payload";
    }
    return false;
  }

  if (masked) {
    for (uint64_t i = 0; i < payload_len; ++i) {
      payload[static_cast<size_t>(i)] ^= masking_key[i % 4];
    }
  }

  if (out_frame != nullptr) {
    out_frame->fin = fin;
    out_frame->opcode = opcode;
    out_frame->payload = std::move(payload);
  }
  return true;
}

bool SendWebSocketFrame(int fd, WsOpcode opcode, const std::string& payload, std::string* error) {
  std::vector<uint8_t> frame;
  frame.reserve(payload.size() + 16);

  const uint8_t first = 0x80 | static_cast<uint8_t>(opcode);
  frame.push_back(first);

  if (payload.size() < 126) {
    frame.push_back(static_cast<uint8_t>(payload.size()));
  } else if (payload.size() <= 0xFFFF) {
    frame.push_back(126);
    const uint16_t ext = htons(static_cast<uint16_t>(payload.size()));
    const uint8_t* ext_ptr = reinterpret_cast<const uint8_t*>(&ext);
    frame.insert(frame.end(), ext_ptr, ext_ptr + sizeof(ext));
  } else {
    frame.push_back(127);
    const uint64_t ext = OSSwapHostToBigInt64(static_cast<uint64_t>(payload.size()));
    const uint8_t* ext_ptr = reinterpret_cast<const uint8_t*>(&ext);
    frame.insert(frame.end(), ext_ptr, ext_ptr + sizeof(ext));
  }

  frame.insert(frame.end(), payload.begin(), payload.end());

  if (!SendAll(fd, frame.data(), frame.size())) {
    if (error != nullptr) {
      *error = "failed to send websocket frame";
    }
    return false;
  }

  return true;
}

class BridgeService {
 public:
  explicit BridgeService(BridgeConfig config) : config_(std::move(config)) {}

  int Run() {
    if (!StartHelper()) {
      return 1;
    }

    listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0) {
      std::cerr << "Failed to create listening socket\n";
      return 1;
    }

    const int one = 1;
    setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(config_.port));
    if (inet_pton(AF_INET, config_.host.c_str(), &addr.sin_addr) != 1) {
      std::cerr << "Invalid websocket.host in config: " << config_.host << "\n";
      return 1;
    }

    if (bind(listen_fd_, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
      std::cerr << "Failed to bind websocket server on " << config_.host << ":" << config_.port
                << " (" << std::strerror(errno) << ")\n";
      return 1;
    }

    if (listen(listen_fd_, 8) != 0) {
      std::cerr << "Failed to listen on websocket socket\n";
      return 1;
    }

    std::cout << "Bridge service listening on ws://" << config_.host << ":" << config_.port << "\n";
    VLOG("Entering main event loop");

    auto last_heartbeat_sent = std::chrono::steady_clock::now();
    auto last_helper_activity = std::chrono::steady_clock::now();

    while (!g_should_exit.load(std::memory_order_relaxed)) {
      if (!helper_.IsRunning()) {
        if (helper_restart_budget_ > 0) {
          std::cerr << "Helper process exited; restarting...\n";
          --helper_restart_budget_;
          if (!StartHelper()) {
            std::cerr << "Helper restart failed\n";
            break;
          }
          if (session_configured_) {
            SendSessionConfigToHelper();
          }
          last_helper_activity = std::chrono::steady_clock::now();
        } else {
          std::cerr << "Helper process exited permanently\n";
          SendErrorToClient("helper_exited", "Engine helper process stopped");
          break;
        }
      }

      FlushHelperEvents(&last_helper_activity);

      const auto now = std::chrono::steady_clock::now();
      if (std::chrono::duration_cast<std::chrono::seconds>(now - last_heartbeat_sent).count() >= 5) {
        SendHeartbeat();
        last_heartbeat_sent = now;
      }

      if (std::chrono::duration_cast<std::chrono::seconds>(now - last_helper_activity).count() > 30 &&
          helper_.IsRunning()) {
        std::cerr << "Helper heartbeat timeout; forcing restart\n";
        helper_.Stop();
        continue;
      }

      if (active_client_fd_ < 0) {
        AcceptPrimaryClient();
      } else {
        PollActiveClient();
      }
    }

    CloseActiveClient();
    CloseFd(&listen_fd_);
    helper_.Stop();
    return 0;
  }

 private:
  bool StartHelper() {
    if (!FileIsExecutable(config_.helper_path)) {
      std::cerr << "Helper executable not found or not executable: " << config_.helper_path << "\n";
      std::cerr << "Build helper with: swift build --package-path swift --product engine_helper -c release\n";
      return false;
    }

    std::string error;
    const bool started = helper_.Start(
        config_.helper_path,
        [this](const std::string& line) {
          std::lock_guard<std::mutex> lock(helper_queue_mutex_);
          helper_events_.push_back(line);
        },
        &error);

    if (!started) {
      std::cerr << "Failed to start helper process: " << error << "\n";
      return false;
    }

    NSDictionary* engine_config = @{
      @"type" : @"engine_config",
      @"audio" : @{
        @"sample_rate_hz" : @(config_.audio.sample_rate_hz),
        @"channels" : @(config_.audio.channels),
        @"ring_capacity_frames" : @(config_.audio.ring_capacity_frames),
      },
      @"elevenlabs" : @{
        @"api_key" : StdStringToNSString(config_.elevenlabs.api_key),
        @"tts" : @{
          @"voice_id" : StdStringToNSString(config_.elevenlabs.tts.voice_id),
          @"model_id" : StdStringToNSString(config_.elevenlabs.tts.model_id),
          @"output_format" : StdStringToNSString(config_.elevenlabs.tts.output_format),
        },
        @"stt" : @{
          @"model_id" : StdStringToNSString(config_.elevenlabs.stt.model_id),
          @"language_code" : StdStringToNSString(config_.elevenlabs.stt.language_code),
        },
      },
      @"apple" : @{
        @"locale" : StdStringToNSString(config_.apple.locale),
        @"on_device_only" : @(config_.apple.on_device_only),
      },
      @"rings" : @{
        @"mic_feed" : @"/virtual_audio_bridge_mic_feed",
        @"speaker_tap" : @"/virtual_audio_bridge_speaker_tap",
      },
    };

    std::string json_error;
    const std::string payload = SerializeJsonObject(engine_config, &json_error);
    if (payload.empty()) {
      std::cerr << "Failed to serialize engine config: " << json_error << "\n";
      return false;
    }

    if (!helper_.SendLine(payload, &json_error)) {
      std::cerr << "Failed to send engine config to helper: " << json_error << "\n";
      return false;
    }

    return true;
  }

  bool SendJsonToClient(NSDictionary* obj) {
    if (active_client_fd_ < 0) {
      return false;
    }
    std::string error;
    const std::string payload = SerializeJsonObject(obj, &error);
    if (payload.empty()) {
      std::cerr << "Failed to serialize websocket response: " << error << "\n";
      return false;
    }
    VLOG("Client << " << payload);
    if (!SendWebSocketFrame(active_client_fd_, WsOpcode::kText, payload, &error)) {
      std::cerr << "Failed to send websocket response: " << error << "\n";
      CloseActiveClient();
      return false;
    }
    return true;
  }

  void SendErrorToClient(const std::string& code, const std::string& message) {
    NSDictionary* payload = @{
      @"type" : @"error",
      @"code" : StdStringToNSString(code),
      @"message" : StdStringToNSString(message),
    };
    (void)SendJsonToClient(payload);
  }

  void SendHeartbeat() {
    NSDictionary* payload = @{@"type" : @"heartbeat"};
    std::string error;
    const std::string line = SerializeJsonObject(payload, &error);
    if (!line.empty()) {
      (void)helper_.SendLine(line, &error);
    }
  }

  void SendSessionConfigToHelper() {
    NSDictionary* session = @{
      @"type" : @"session_config",
      @"mode" : StdStringToNSString(session_mode_),
      @"stt_source" : StdStringToNSString(session_stt_source_),
      @"tts_target" : StdStringToNSString(session_tts_target_),
    };

    std::string error;
    const std::string line = SerializeJsonObject(session, &error);
    if (line.empty() || !helper_.SendLine(line, &error)) {
      std::cerr << "Failed to send session config to helper: " << error << "\n";
    }
  }

  void AcceptPrimaryClient() {
    struct pollfd pfd {};
    pfd.fd = listen_fd_;
    pfd.events = POLLIN;
    if (poll(&pfd, 1, 200) <= 0) {
      return;
    }

    sockaddr_in addr {};
    socklen_t addr_len = sizeof(addr);
    int fd = accept(listen_fd_, reinterpret_cast<sockaddr*>(&addr), &addr_len);
    if (fd < 0) {
      return;
    }

    std::string handshake_error;
    std::string handshake_extra;
    if (!PerformWebSocketHandshake(fd, &handshake_extra, &handshake_error)) {
      RejectHttpConnection(fd, 400, "invalid websocket handshake");
      return;
    }

    VLOG("Client connected, fd=" << fd);
    active_client_fd_ = fd;
    client_pending_bytes_ = std::move(handshake_extra);
    session_configured_ = false;
    session_mode_ = config_.session_defaults.mode;
    session_stt_source_ = config_.session_defaults.stt_source;
    session_tts_target_ = config_.session_defaults.tts_target;

    NSDictionary* ready = @{
      @"type" : @"ready",
      @"version" : StdStringToNSString(kProtocolVersion),
    };
    (void)SendJsonToClient(ready);
  }

  void RejectSecondaryClient() {
    sockaddr_in addr {};
    socklen_t addr_len = sizeof(addr);
    int fd = accept(listen_fd_, reinterpret_cast<sockaddr*>(&addr), &addr_len);
    if (fd < 0) {
      return;
    }
    RejectHttpConnection(fd, 409, "single active websocket client supported");
  }

  void CloseActiveClient() {
    if (active_client_fd_ >= 0) {
      VLOG("Closing client fd=" << active_client_fd_);
      std::string ignored;
      (void)SendWebSocketFrame(active_client_fd_, WsOpcode::kClose, "", &ignored);
      close(active_client_fd_);
      active_client_fd_ = -1;
    }
    client_pending_bytes_.clear();
    session_configured_ = false;
  }

  void FlushHelperEvents(std::chrono::steady_clock::time_point* last_helper_activity) {
    std::deque<std::string> events;
    {
      std::lock_guard<std::mutex> lock(helper_queue_mutex_);
      events.swap(helper_events_);
    }

    for (const std::string& line : events) {
      if (last_helper_activity != nullptr) {
        *last_helper_activity = std::chrono::steady_clock::now();
      }

      if (active_client_fd_ < 0) {
        continue;
      }

      std::string error;
      if (!SendWebSocketFrame(active_client_fd_, WsOpcode::kText, line, &error)) {
        std::cerr << "Failed to relay helper event to websocket client: " << error << "\n";
        CloseActiveClient();
        break;
      }
    }
  }

  bool ForwardJsonToHelper(NSDictionary* payload) {
    std::string error;
    const std::string line = SerializeJsonObject(payload, &error);
    if (line.empty()) {
      SendErrorToClient("internal_error", "failed to serialize helper command");
      return false;
    }
    if (!helper_.SendLine(line, &error)) {
      SendErrorToClient("helper_unavailable", "engine helper is unavailable");
      return false;
    }
    return true;
  }

  void HandleClientMessage(const std::string& text_payload) {
    VLOG("Client >> " << text_payload);
    std::string json_error;
    NSDictionary* obj = ParseJsonObject(text_payload, &json_error);
    if (obj == nil) {
      SendErrorToClient("invalid_json", "message is not valid JSON object");
      return;
    }

    auto type_opt = StringForKey(obj, @"type");
    if (!type_opt) {
      SendErrorToClient("invalid_message", "message missing type field");
      return;
    }

    const std::string type = *type_opt;

    if (type == "ping") {
      std::string id;
      if (auto id_opt = StringForKey(obj, @"id")) {
        id = *id_opt;
      }
      NSDictionary* pong = @{
        @"type" : @"pong",
        @"id" : StdStringToNSString(id),
      };
      (void)SendJsonToClient(pong);
      return;
    }

    if (type == "configure_session") {
      std::string mode = session_mode_;
      std::string stt_source = session_stt_source_;
      std::string tts_target = session_tts_target_;

      if (auto mode_opt = StringForKey(obj, @"mode")) {
        mode = ToLower(*mode_opt);
      }
      if (auto stt_opt = StringForKey(obj, @"stt_source")) {
        stt_source = *stt_opt;
      }
      if (auto tts_opt = StringForKey(obj, @"tts_target")) {
        tts_target = *tts_opt;
      }

      if (mode != "apple" && mode != "elevenlabs") {
        SendErrorToClient("invalid_mode", "mode must be apple or elevenlabs");
        return;
      }

      if (stt_source != "virtual_speaker" && stt_source != "virtual_mic") {
        SendErrorToClient("invalid_stt_source", "stt_source must be virtual_speaker or virtual_mic");
        return;
      }

      if (tts_target != "virtual_mic" && tts_target != "virtual_speaker" && tts_target != "both") {
        SendErrorToClient("invalid_tts_target", "tts_target must be virtual_mic, virtual_speaker, or both");
        return;
      }

      if (mode == "elevenlabs" && config_.elevenlabs.api_key.empty()) {
        SendErrorToClient("missing_api_key",
                          "ELEVENLABS_API_KEY is not set (or configured env var missing)");
        return;
      }

      session_mode_ = mode;
      session_stt_source_ = stt_source;
      session_tts_target_ = tts_target;
      session_configured_ = true;

      VLOG("Session configured: mode=" << mode << " stt_source=" << stt_source << " tts_target=" << tts_target);
      SendSessionConfigToHelper();

      NSDictionary* ack = @{
        @"type" : @"session_config_applied",
        @"mode" : StdStringToNSString(mode),
      };
      (void)SendJsonToClient(ack);
      return;
    }

    if (!session_configured_) {
      SendErrorToClient("session_not_configured", "configure_session must be sent before TTS/STT commands");
      return;
    }

    static const std::vector<std::string> allowed_forward_types = {
        "tts_start", "tts_chunk", "tts_flush", "tts_cancel", "start_stt", "stop_stt"};

    if (std::find(allowed_forward_types.begin(), allowed_forward_types.end(), type) ==
        allowed_forward_types.end()) {
      SendErrorToClient("unknown_message_type", "unsupported message type");
      return;
    }

    NSMutableDictionary* forward = [obj mutableCopy];
    if (type == "start_stt" && StringForKey(obj, @"language") == std::nullopt) {
      forward[@"language"] = StdStringToNSString(config_.apple.locale);
    }

    VLOG("Forwarding to helper: type=" << type);
    (void)ForwardJsonToHelper(forward);
  }

  void PollActiveClient() {
    struct pollfd pfds[2] {};
    pfds[0].fd = listen_fd_;
    pfds[0].events = POLLIN;
    pfds[1].fd = active_client_fd_;
    pfds[1].events = POLLIN;

    const int rc = poll(pfds, 2, 100);
    if (rc <= 0) {
      return;
    }

    if ((pfds[0].revents & POLLIN) != 0) {
      RejectSecondaryClient();
    }

    if ((pfds[1].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0) {
      CloseActiveClient();
      return;
    }

    if ((pfds[1].revents & POLLIN) != 0) {
      WsFrame frame;
      std::string error;
      if (!ReadWebSocketFrame(active_client_fd_, &client_pending_bytes_, &frame, 1000, &error)) {
        CloseActiveClient();
        return;
      }

      switch (frame.opcode) {
        case WsOpcode::kText:
          HandleClientMessage(frame.payload);
          break;
        case WsOpcode::kPing:
          (void)SendWebSocketFrame(active_client_fd_, WsOpcode::kPong, frame.payload, &error);
          break;
        case WsOpcode::kClose:
          CloseActiveClient();
          break;
        default:
          break;
      }
    }
  }

  BridgeConfig config_;
  HelperProcess helper_;
  int listen_fd_ = -1;
  int active_client_fd_ = -1;
  std::string client_pending_bytes_;

  bool session_configured_ = false;
  std::string session_mode_;
  std::string session_stt_source_;
  std::string session_tts_target_;

  int helper_restart_budget_ = 1;

  std::mutex helper_queue_mutex_;
  std::deque<std::string> helper_events_;
};

void PrintUsage(const char* program_name) {
  std::cerr
      << "Usage:\n"
      << "  " << program_name << " service --config <path> [--verbose]\n"
      << "  " << program_name << " doctor --config <path>\n"
      << "  " << program_name << " debug-tone [--seconds N]\n"
      << "  " << program_name << " debug-loopback [--seconds N]\n";
}

int ParseSecondsFlag(int argc, char** argv, int default_seconds) {
  int seconds = default_seconds;
  for (int i = 2; i < argc; ++i) {
    if (std::strcmp(argv[i], "--seconds") == 0 && i + 1 < argc) {
      seconds = std::max(1, std::atoi(argv[++i]));
    }
  }
  return seconds;
}

std::string ParseConfigFlag(int argc, char** argv) {
  for (int i = 2; i < argc; ++i) {
    if (std::strcmp(argv[i], "--config") == 0 && i + 1 < argc) {
      return argv[++i];
    }
  }
  return "";
}

bool ParseVerboseFlag(int argc, char** argv) {
  for (int i = 2; i < argc; ++i) {
    if (std::strcmp(argv[i], "--verbose") == 0 || std::strcmp(argv[i], "-v") == 0) {
      return true;
    }
  }
  return false;
}

int RunDebugTone(int seconds) {
  bridge::SharedMemoryAudioRing mic_feed;
  if (!mic_feed.Open(kMicFeedName, true, kChannels, kRingCapacityFrames)) {
    std::cerr << "Failed to open mic feed ring\n";
    return 1;
  }

  std::vector<float> chunk(kChunkFrames * kChannels, 0.0f);
  const int total_iterations = (seconds * static_cast<int>(kSampleRate)) /
                               static_cast<int>(kChunkFrames);

  float phase = 0.0f;
  constexpr float kFrequency = 440.0f;
  const float phase_step = 2.0f * static_cast<float>(M_PI) * kFrequency /
                           static_cast<float>(kSampleRate);

  std::cout << "Running debug-tone for " << seconds << "s\n";
  for (int i = 0; i < total_iterations; ++i) {
    for (uint32_t frame = 0; frame < kChunkFrames; ++frame) {
      const float sample = 0.1f * std::sin(phase);
      phase += phase_step;
      if (phase > 2.0f * static_cast<float>(M_PI)) {
        phase -= 2.0f * static_cast<float>(M_PI);
      }
      const size_t idx = static_cast<size_t>(frame) * kChannels;
      chunk[idx] = sample;
      chunk[idx + 1] = sample;
    }
    mic_feed.Write(chunk.data(), kChunkFrames);
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  return 0;
}

int RunDebugLoopback(int seconds) {
  bridge::SharedMemoryAudioRing mic_feed;
  bridge::SharedMemoryAudioRing speaker_tap;

  if (!mic_feed.Open(kMicFeedName, true, kChannels, kRingCapacityFrames)) {
    std::cerr << "Failed to open mic feed ring\n";
    return 1;
  }
  if (!speaker_tap.Open(kSpeakerTapName, true, kChannels, kRingCapacityFrames)) {
    std::cerr << "Failed to open speaker tap ring\n";
    return 1;
  }

  std::vector<float> chunk(kChunkFrames * kChannels, 0.0f);
  const int total_iterations = (seconds * static_cast<int>(kSampleRate)) /
                               static_cast<int>(kChunkFrames);

  std::cout << "Running debug-loopback for " << seconds << "s\n";
  for (int i = 0; i < total_iterations; ++i) {
    const size_t got = speaker_tap.Read(chunk.data(), kChunkFrames);
    if (got > 0) {
      mic_feed.Write(chunk.data(), got);
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(10));
  }

  return 0;
}

int RunDoctor(const std::string& config_path) {
  BridgeConfig config;
  std::string error;
  if (!LoadConfig(config_path, &config, &error)) {
    std::cerr << "Config validation failed: " << error << "\n";
    return 1;
  }

  bool ok = true;

  std::cout << "Config OK\n";
  std::cout << "  websocket: " << config.host << ":" << config.port << "\n";
  std::cout << "  default mode: " << config.session_defaults.mode << "\n";
  std::cout << "  helper path: " << config.helper_path << "\n";

  if (!FileIsExecutable(config.helper_path)) {
    std::cerr << "FAIL: helper executable missing or not executable: " << config.helper_path << "\n";
    ok = false;
  } else {
    std::cout << "PASS: helper executable found\n";
  }

  if (config.session_defaults.mode == "elevenlabs") {
    if (config.elevenlabs.api_key.empty()) {
      std::cerr << "FAIL: ElevenLabs mode defaulted but API key env var not set: "
                << config.elevenlabs.api_key_env << "\n";
      ok = false;
    } else {
      std::cout << "PASS: ElevenLabs API key env resolved\n";
    }

    if (config.elevenlabs.tts.voice_id.empty()) {
      std::cerr << "FAIL: elevenlabs.tts.voice_id missing\n";
      ok = false;
    } else {
      std::cout << "PASS: ElevenLabs voice id present\n";
    }
  }

  bridge::SharedMemoryAudioRing mic_feed;
  bridge::SharedMemoryAudioRing speaker_tap;
  if (!mic_feed.Open(kMicFeedName, true, kChannels, kRingCapacityFrames)) {
    std::cerr << "FAIL: unable to open mic feed ring\n";
    ok = false;
  } else {
    std::cout << "PASS: mic feed ring accessible\n";
  }
  if (!speaker_tap.Open(kSpeakerTapName, true, kChannels, kRingCapacityFrames)) {
    std::cerr << "FAIL: unable to open speaker tap ring\n";
    ok = false;
  } else {
    std::cout << "PASS: speaker tap ring accessible\n";
  }

  return ok ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
  signal(SIGINT, SignalHandler);
  signal(SIGTERM, SignalHandler);

  if (argc < 2) {
    PrintUsage(argv[0]);
    return 2;
  }

  const std::string command = argv[1];

  if (command == "debug-tone") {
    return RunDebugTone(ParseSecondsFlag(argc, argv, 10));
  }

  if (command == "debug-loopback") {
    return RunDebugLoopback(ParseSecondsFlag(argc, argv, 10));
  }

  if (command == "doctor") {
    const std::string config_path = ParseConfigFlag(argc, argv);
    if (config_path.empty()) {
      std::cerr << "doctor requires --config <path>\n";
      return 2;
    }
    return RunDoctor(config_path);
  }

  if (command == "service") {
    const std::string config_path = ParseConfigFlag(argc, argv);
    if (config_path.empty()) {
      std::cerr << "service requires --config <path>\n";
      return 2;
    }

    g_verbose = ParseVerboseFlag(argc, argv);
    if (g_verbose) {
      std::cerr << "[verbose] Verbose logging enabled\n";
    }

    BridgeConfig config;
    std::string error;
    if (!LoadConfig(config_path, &config, &error)) {
      std::cerr << "Failed to load config: " << error << "\n";
      return 1;
    }

    BridgeService service(config);
    return service.Run();
  }

  PrintUsage(argv[0]);
  return 2;
}
