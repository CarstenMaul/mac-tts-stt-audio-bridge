#include "SharedMemoryAudioRing.h"

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/HostTime.h>
#include <CoreFoundation/CFBase.h>

#include <atomic>
#include <cstring>
#include <mutex>

namespace {

constexpr AudioObjectID kObjectIDPlugIn = kAudioObjectPlugInObject;
constexpr AudioObjectID kObjectIDDevice = 2;
constexpr AudioObjectID kObjectIDStreamInput = 3;
constexpr AudioObjectID kObjectIDStreamOutput = 4;

constexpr UInt32 kChannelCount = 2;
constexpr Float64 kDefaultSampleRate = 48000.0;
constexpr UInt32 kDefaultBufferFrameSize = 480;

constexpr const char* kDriverName = "Virtual Audio Bridge";
constexpr const char* kDriverManufacturer = "stt-tts-audio-bridge";
constexpr const char* kDeviceUID = "com.zaphbot.VirtualAudioBridge.Device";
constexpr const char* kModelUID = "com.zaphbot.VirtualAudioBridge.Model";
constexpr const char* kInputStreamName = "Virtual Microphone";
constexpr const char* kOutputStreamName = "Virtual Speaker";
constexpr const char* kMicFeedRingName = "/virtual_audio_bridge_mic_feed";
constexpr const char* kSpeakerTapRingName = "/virtual_audio_bridge_speaker_tap";

AudioServerPlugInHostRef g_host = nullptr;
std::atomic<UInt32> g_ref_count{1};
std::atomic<UInt32> g_io_client_count{0};
std::atomic<Float64> g_sample_rate{kDefaultSampleRate};
std::atomic<UInt32> g_buffer_frame_size{kDefaultBufferFrameSize};
std::atomic<UInt64> g_clock_seed{1};
std::atomic<UInt64> g_anchor_host_time{0};
std::atomic<Float64> g_anchor_sample_time{0.0};
std::mutex g_ring_mutex;
bridge::SharedMemoryAudioRing g_mic_feed_ring;
bridge::SharedMemoryAudioRing g_speaker_tap_ring;

inline bool IsEqualUUID(REFIID in_a, CFUUIDRef in_b) {
  const CFUUIDBytes bytes = CFUUIDGetUUIDBytes(in_b);
  return std::memcmp(&in_a, &bytes, sizeof(CFUUIDBytes)) == 0;
}

inline AudioStreamBasicDescription MakeStreamFormat(Float64 sample_rate) {
  AudioStreamBasicDescription asbd{};
  asbd.mSampleRate = sample_rate;
  asbd.mFormatID = kAudioFormatLinearPCM;
  asbd.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
  asbd.mBytesPerPacket = sizeof(float) * kChannelCount;
  asbd.mFramesPerPacket = 1;
  asbd.mBytesPerFrame = sizeof(float) * kChannelCount;
  asbd.mChannelsPerFrame = kChannelCount;
  asbd.mBitsPerChannel = 8U * sizeof(float);
  return asbd;
}

inline bool IsKnownObject(AudioObjectID object_id) {
  return object_id == kObjectIDPlugIn || object_id == kObjectIDDevice ||
         object_id == kObjectIDStreamInput || object_id == kObjectIDStreamOutput;
}

void NotifyPropertiesChanged(AudioObjectID object_id,
                             UInt32 count,
                             const AudioObjectPropertyAddress* addresses) {
  if (g_host != nullptr && g_host->PropertiesChanged != nullptr) {
    g_host->PropertiesChanged(g_host, object_id, count, addresses);
  }
}

template <typename T>
OSStatus WriteSingleValue(UInt32 in_data_size, UInt32* out_data_size, void* out_data, const T& value) {
  if (in_data_size < sizeof(T) || out_data == nullptr) {
    return kAudioHardwareBadPropertySizeError;
  }
  std::memcpy(out_data, &value, sizeof(T));
  if (out_data_size != nullptr) {
    *out_data_size = sizeof(T);
  }
  return kAudioHardwareNoError;
}

OSStatus WriteCFObject(UInt32 in_data_size, UInt32* out_data_size, void* out_data, CFTypeRef object) {
  if (in_data_size < sizeof(CFTypeRef) || out_data == nullptr) {
    return kAudioHardwareBadPropertySizeError;
  }
  if (object != nullptr) {
    CFRetain(object);
  }
  std::memcpy(out_data, &object, sizeof(object));
  if (out_data_size != nullptr) {
    *out_data_size = sizeof(object);
  }
  return kAudioHardwareNoError;
}

OSStatus WriteCStringAsCFString(UInt32 in_data_size,
                                UInt32* out_data_size,
                                void* out_data,
                                const char* value) {
  CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, value, kCFStringEncodingUTF8);
  if (s == nullptr) {
    return kAudioHardwareUnspecifiedError;
  }
  const OSStatus status = WriteCFObject(in_data_size, out_data_size, out_data, s);
  CFRelease(s);
  return status;
}

HRESULT DriverQueryInterface(void* in_driver, REFIID in_uuid, LPVOID* out_interface);
ULONG DriverAddRef(void* in_driver);
ULONG DriverRelease(void* in_driver);
OSStatus DriverInitialize(AudioServerPlugInDriverRef in_driver, AudioServerPlugInHostRef in_host);
OSStatus DriverCreateDevice(AudioServerPlugInDriverRef in_driver,
                            CFDictionaryRef in_description,
                            const AudioServerPlugInClientInfo* in_client_info,
                            AudioObjectID* out_device_object_id);
OSStatus DriverDestroyDevice(AudioServerPlugInDriverRef in_driver, AudioObjectID in_device_object_id);
OSStatus DriverAddDeviceClient(AudioServerPlugInDriverRef in_driver,
                               AudioObjectID in_device_object_id,
                               const AudioServerPlugInClientInfo* in_client_info);
OSStatus DriverRemoveDeviceClient(AudioServerPlugInDriverRef in_driver,
                                  AudioObjectID in_device_object_id,
                                  const AudioServerPlugInClientInfo* in_client_info);
OSStatus DriverPerformDeviceConfigurationChange(AudioServerPlugInDriverRef in_driver,
                                                AudioObjectID in_device_object_id,
                                                UInt64 in_change_action,
                                                void* in_change_info);
OSStatus DriverAbortDeviceConfigurationChange(AudioServerPlugInDriverRef in_driver,
                                              AudioObjectID in_device_object_id,
                                              UInt64 in_change_action,
                                              void* in_change_info);
Boolean DriverHasProperty(AudioServerPlugInDriverRef in_driver,
                          AudioObjectID in_object_id,
                          pid_t in_client_process_id,
                          const AudioObjectPropertyAddress* in_address);
OSStatus DriverIsPropertySettable(AudioServerPlugInDriverRef in_driver,
                                  AudioObjectID in_object_id,
                                  pid_t in_client_process_id,
                                  const AudioObjectPropertyAddress* in_address,
                                  Boolean* out_is_settable);
OSStatus DriverGetPropertyDataSize(AudioServerPlugInDriverRef in_driver,
                                   AudioObjectID in_object_id,
                                   pid_t in_client_process_id,
                                   const AudioObjectPropertyAddress* in_address,
                                   UInt32 in_qualifier_data_size,
                                   const void* in_qualifier_data,
                                   UInt32* out_data_size);
OSStatus DriverGetPropertyData(AudioServerPlugInDriverRef in_driver,
                               AudioObjectID in_object_id,
                               pid_t in_client_process_id,
                               const AudioObjectPropertyAddress* in_address,
                               UInt32 in_qualifier_data_size,
                               const void* in_qualifier_data,
                               UInt32 in_data_size,
                               UInt32* out_data_size,
                               void* out_data);
OSStatus DriverSetPropertyData(AudioServerPlugInDriverRef in_driver,
                               AudioObjectID in_object_id,
                               pid_t in_client_process_id,
                               const AudioObjectPropertyAddress* in_address,
                               UInt32 in_qualifier_data_size,
                               const void* in_qualifier_data,
                               UInt32 in_data_size,
                               const void* in_data);
OSStatus DriverStartIO(AudioServerPlugInDriverRef in_driver,
                       AudioObjectID in_device_object_id,
                       UInt32 in_client_id);
OSStatus DriverStopIO(AudioServerPlugInDriverRef in_driver,
                      AudioObjectID in_device_object_id,
                      UInt32 in_client_id);
OSStatus DriverGetZeroTimeStamp(AudioServerPlugInDriverRef in_driver,
                                AudioObjectID in_device_object_id,
                                UInt32 in_client_id,
                                Float64* out_sample_time,
                                UInt64* out_host_time,
                                UInt64* out_seed);
OSStatus DriverWillDoIOOperation(AudioServerPlugInDriverRef in_driver,
                                 AudioObjectID in_device_object_id,
                                 UInt32 in_client_id,
                                 UInt32 in_operation_id,
                                 Boolean* out_will_do,
                                 Boolean* out_will_do_in_place);
OSStatus DriverBeginIOOperation(AudioServerPlugInDriverRef in_driver,
                                AudioObjectID in_device_object_id,
                                UInt32 in_client_id,
                                UInt32 in_operation_id,
                                UInt32 in_io_buffer_frame_size,
                                const AudioServerPlugInIOCycleInfo* in_io_cycle_info);
OSStatus DriverDoIOOperation(AudioServerPlugInDriverRef in_driver,
                             AudioObjectID in_device_object_id,
                             AudioObjectID in_stream_object_id,
                             UInt32 in_client_id,
                             UInt32 in_operation_id,
                             UInt32 in_io_buffer_frame_size,
                             const AudioServerPlugInIOCycleInfo* in_io_cycle_info,
                             void* io_main_buffer,
                             void* io_secondary_buffer);
OSStatus DriverEndIOOperation(AudioServerPlugInDriverRef in_driver,
                              AudioObjectID in_device_object_id,
                              UInt32 in_client_id,
                              UInt32 in_operation_id,
                              UInt32 in_io_buffer_frame_size,
                              const AudioServerPlugInIOCycleInfo* in_io_cycle_info);

AudioServerPlugInDriverInterface g_driver_interface = {
    nullptr,
    DriverQueryInterface,
    DriverAddRef,
    DriverRelease,
    DriverInitialize,
    DriverCreateDevice,
    DriverDestroyDevice,
    DriverAddDeviceClient,
    DriverRemoveDeviceClient,
    DriverPerformDeviceConfigurationChange,
    DriverAbortDeviceConfigurationChange,
    DriverHasProperty,
    DriverIsPropertySettable,
    DriverGetPropertyDataSize,
    DriverGetPropertyData,
    DriverSetPropertyData,
    DriverStartIO,
    DriverStopIO,
    DriverGetZeroTimeStamp,
    DriverWillDoIOOperation,
    DriverBeginIOOperation,
    DriverDoIOOperation,
    DriverEndIOOperation};

AudioServerPlugInDriverInterface* g_driver_interface_ptr = &g_driver_interface;
AudioServerPlugInDriverRef g_driver_ref = &g_driver_interface_ptr;

HRESULT DriverQueryInterface(void* in_driver, REFIID in_uuid, LPVOID* out_interface) {
  if (out_interface == nullptr) {
    return E_POINTER;
  }
  *out_interface = nullptr;

  if (IsEqualUUID(in_uuid, IUnknownUUID) || IsEqualUUID(in_uuid, kAudioServerPlugInDriverInterfaceUUID)) {
    DriverAddRef(in_driver);
    *out_interface = in_driver;
    return S_OK;
  }
  return E_NOINTERFACE;
}

ULONG DriverAddRef(void* /*in_driver*/) {
  return g_ref_count.fetch_add(1, std::memory_order_relaxed) + 1;
}

ULONG DriverRelease(void* /*in_driver*/) {
  const UInt32 current = g_ref_count.load(std::memory_order_relaxed);
  if (current == 0) {
    return 0;
  }
  return g_ref_count.fetch_sub(1, std::memory_order_relaxed) - 1;
}

OSStatus DriverInitialize(AudioServerPlugInDriverRef /*in_driver*/, AudioServerPlugInHostRef in_host) {
  g_host = in_host;

  std::lock_guard<std::mutex> lock(g_ring_mutex);
  (void)g_mic_feed_ring.Open(kMicFeedRingName, true, kChannelCount, 48000);
  (void)g_speaker_tap_ring.Open(kSpeakerTapRingName, true, kChannelCount, 48000);
  return kAudioHardwareNoError;
}

OSStatus DriverCreateDevice(AudioServerPlugInDriverRef /*in_driver*/,
                            CFDictionaryRef /*in_description*/,
                            const AudioServerPlugInClientInfo* /*in_client_info*/,
                            AudioObjectID* /*out_device_object_id*/) {
  return kAudioHardwareUnsupportedOperationError;
}

OSStatus DriverDestroyDevice(AudioServerPlugInDriverRef /*in_driver*/,
                             AudioObjectID /*in_device_object_id*/) {
  return kAudioHardwareUnsupportedOperationError;
}

OSStatus DriverAddDeviceClient(AudioServerPlugInDriverRef /*in_driver*/,
                               AudioObjectID in_device_object_id,
                               const AudioServerPlugInClientInfo* /*in_client_info*/) {
  if (in_device_object_id != kObjectIDDevice) {
    return kAudioHardwareBadObjectError;
  }
  return kAudioHardwareNoError;
}

OSStatus DriverRemoveDeviceClient(AudioServerPlugInDriverRef /*in_driver*/,
                                  AudioObjectID in_device_object_id,
                                  const AudioServerPlugInClientInfo* /*in_client_info*/) {
  if (in_device_object_id != kObjectIDDevice) {
    return kAudioHardwareBadObjectError;
  }
  return kAudioHardwareNoError;
}

OSStatus DriverPerformDeviceConfigurationChange(AudioServerPlugInDriverRef /*in_driver*/,
                                                AudioObjectID in_device_object_id,
                                                UInt64 /*in_change_action*/,
                                                void* /*in_change_info*/) {
  return in_device_object_id == kObjectIDDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus DriverAbortDeviceConfigurationChange(AudioServerPlugInDriverRef /*in_driver*/,
                                              AudioObjectID in_device_object_id,
                                              UInt64 /*in_change_action*/,
                                              void* /*in_change_info*/) {
  return in_device_object_id == kObjectIDDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

Boolean DriverHasProperty(AudioServerPlugInDriverRef /*in_driver*/,
                          AudioObjectID in_object_id,
                          pid_t /*in_client_process_id*/,
                          const AudioObjectPropertyAddress* in_address) {
  if (in_address == nullptr || !IsKnownObject(in_object_id)) {
    return false;
  }

  switch (in_object_id) {
    case kObjectIDPlugIn:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
        case kAudioPlugInPropertyResourceBundle:
          return true;
        default:
          return false;
      }
    case kObjectIDDevice:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertyStreamConfiguration:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertyBufferFrameSizeRange:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockIsStable:
        case kAudioDevicePropertyIsHidden:
          return true;
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
          return in_address->mScope == kAudioObjectPropertyScopeInput ||
                 in_address->mScope == kAudioObjectPropertyScopeOutput;
        default:
          return false;
      }
    case kObjectIDStreamInput:
    case kObjectIDStreamOutput:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailablePhysicalFormats:
        case kAudioStreamPropertyIsActive:
          return true;
        default:
          return false;
      }
    default:
      return false;
  }
}

OSStatus DriverIsPropertySettable(AudioServerPlugInDriverRef /*in_driver*/,
                                  AudioObjectID in_object_id,
                                  pid_t /*in_client_process_id*/,
                                  const AudioObjectPropertyAddress* in_address,
                                  Boolean* out_is_settable) {
  if (in_address == nullptr || out_is_settable == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!IsKnownObject(in_object_id)) {
    return kAudioHardwareBadObjectError;
  }

  *out_is_settable = false;
  if (in_object_id == kObjectIDDevice &&
      (in_address->mSelector == kAudioDevicePropertyNominalSampleRate ||
       in_address->mSelector == kAudioDevicePropertyBufferFrameSize)) {
    *out_is_settable = true;
  }
  if ((in_object_id == kObjectIDStreamInput || in_object_id == kObjectIDStreamOutput) &&
      (in_address->mSelector == kAudioStreamPropertyVirtualFormat ||
       in_address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
    *out_is_settable = true;
  }
  return kAudioHardwareNoError;
}

OSStatus DriverGetPropertyDataSize(AudioServerPlugInDriverRef /*in_driver*/,
                                   AudioObjectID in_object_id,
                                   pid_t /*in_client_process_id*/,
                                   const AudioObjectPropertyAddress* in_address,
                                   UInt32 /*in_qualifier_data_size*/,
                                   const void* /*in_qualifier_data*/,
                                   UInt32* out_data_size) {
  if (in_address == nullptr || out_data_size == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!IsKnownObject(in_object_id)) {
    return kAudioHardwareBadObjectError;
  }

  switch (in_object_id) {
    case kObjectIDPlugIn:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
          *out_data_size = sizeof(AudioClassID);
          return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioPlugInPropertyResourceBundle:
          *out_data_size = sizeof(CFStringRef);
          return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
          *out_data_size = sizeof(AudioObjectID);
          return kAudioHardwareNoError;
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
          *out_data_size = 0;
          return kAudioHardwareNoError;
        default:
          return kAudioHardwareUnknownPropertyError;
      }
    case kObjectIDDevice:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
          *out_data_size = sizeof(AudioClassID);
          return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
          *out_data_size = sizeof(CFStringRef);
          return kAudioHardwareNoError;
        case kAudioObjectPropertyOwnedObjects:
          if (in_address->mScope == kAudioObjectPropertyScopeInput ||
              in_address->mScope == kAudioObjectPropertyScopeOutput) {
            *out_data_size = sizeof(AudioObjectID);
          } else {
            *out_data_size = sizeof(AudioObjectID) * 2;
          }
          return kAudioHardwareNoError;
        case kAudioObjectPropertyControlList:
          *out_data_size = 0;
          return kAudioHardwareNoError;
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyBufferFrameSize:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyClockIsStable:
        case kAudioDevicePropertyIsHidden:
          *out_data_size = sizeof(UInt32);
          return kAudioHardwareNoError;
        case kAudioDevicePropertyRelatedDevices:
          *out_data_size = sizeof(AudioObjectID);
          return kAudioHardwareNoError;
        case kAudioDevicePropertyPreferredChannelsForStereo:
          *out_data_size = sizeof(UInt32) * 2;
          return kAudioHardwareNoError;
        case kAudioDevicePropertyStreams:
          if (in_address->mScope == kAudioObjectPropertyScopeInput ||
              in_address->mScope == kAudioObjectPropertyScopeOutput) {
            *out_data_size = sizeof(AudioObjectID);
          } else {
            *out_data_size = sizeof(AudioObjectID) * 2;
          }
          return kAudioHardwareNoError;
        case kAudioDevicePropertyStreamConfiguration:
          *out_data_size = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer);
          return kAudioHardwareNoError;
        case kAudioDevicePropertyNominalSampleRate:
          *out_data_size = sizeof(Float64);
          return kAudioHardwareNoError;
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyBufferFrameSizeRange:
          *out_data_size = sizeof(AudioValueRange);
          return kAudioHardwareNoError;
        default:
          return kAudioHardwareUnknownPropertyError;
      }
    case kObjectIDStreamInput:
    case kObjectIDStreamOutput:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyIsActive:
          *out_data_size = sizeof(UInt32);
          return kAudioHardwareNoError;
        case kAudioObjectPropertyName:
          *out_data_size = sizeof(CFStringRef);
          return kAudioHardwareNoError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
          *out_data_size = sizeof(AudioStreamBasicDescription);
          return kAudioHardwareNoError;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
          *out_data_size = sizeof(AudioStreamRangedDescription);
          return kAudioHardwareNoError;
        default:
          return kAudioHardwareUnknownPropertyError;
      }
    default:
      return kAudioHardwareBadObjectError;
  }
}

OSStatus DriverGetPropertyData(AudioServerPlugInDriverRef /*in_driver*/,
                               AudioObjectID in_object_id,
                               pid_t /*in_client_process_id*/,
                               const AudioObjectPropertyAddress* in_address,
                               UInt32 in_qualifier_data_size,
                               const void* in_qualifier_data,
                               UInt32 in_data_size,
                               UInt32* out_data_size,
                               void* out_data) {
  if (in_address == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!IsKnownObject(in_object_id)) {
    return kAudioHardwareBadObjectError;
  }

  switch (in_object_id) {
    case kObjectIDPlugIn:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioClassID{kAudioObjectClassID});
        case kAudioObjectPropertyClass:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioClassID{kAudioPlugInClassID});
        case kAudioObjectPropertyOwner:
          return WriteSingleValue(
              in_data_size, out_data_size, out_data, AudioObjectID{kAudioObjectSystemObject});
        case kAudioObjectPropertyName:
          return WriteCStringAsCFString(in_data_size, out_data_size, out_data, kDriverName);
        case kAudioObjectPropertyManufacturer:
          return WriteCStringAsCFString(
              in_data_size, out_data_size, out_data, kDriverManufacturer);
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDDevice});
        case kAudioPlugInPropertyResourceBundle:
          return WriteCStringAsCFString(in_data_size, out_data_size, out_data, "");
        case kAudioPlugInPropertyTranslateUIDToDevice: {
          if (in_qualifier_data_size < sizeof(CFStringRef) || in_qualifier_data == nullptr) {
            return kAudioHardwareIllegalOperationError;
          }
          const CFStringRef requested_uid = *reinterpret_cast<CFStringRef const*>(in_qualifier_data);
          const CFStringRef known_uid =
              CFStringCreateWithCString(kCFAllocatorDefault, kDeviceUID, kCFStringEncodingUTF8);
          AudioObjectID result = kAudioObjectUnknown;
          if (requested_uid != nullptr && known_uid != nullptr && CFEqual(requested_uid, known_uid)) {
            result = kObjectIDDevice;
          }
          if (known_uid != nullptr) {
            CFRelease(known_uid);
          }
          return WriteSingleValue(in_data_size, out_data_size, out_data, result);
        }
        case kAudioPlugInPropertyBoxList:
        case kAudioPlugInPropertyClockDeviceList:
          if (out_data_size != nullptr) {
            *out_data_size = 0;
          }
          return kAudioHardwareNoError;
        default:
          return kAudioHardwareUnknownPropertyError;
      }

    case kObjectIDDevice:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioClassID{kAudioObjectClassID});
        case kAudioObjectPropertyClass:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioClassID{kAudioDeviceClassID});
        case kAudioObjectPropertyOwner:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDPlugIn});
        case kAudioObjectPropertyName:
          return WriteCStringAsCFString(in_data_size, out_data_size, out_data, kDriverName);
        case kAudioObjectPropertyManufacturer:
          return WriteCStringAsCFString(
              in_data_size, out_data_size, out_data, kDriverManufacturer);
        case kAudioObjectPropertyOwnedObjects: {
          if (out_data == nullptr) {
            return kAudioHardwareBadPropertySizeError;
          }
          if (in_address->mScope == kAudioObjectPropertyScopeInput) {
            return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDStreamInput});
          }
          if (in_address->mScope == kAudioObjectPropertyScopeOutput) {
            return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDStreamOutput});
          }
          if (in_data_size < sizeof(AudioObjectID) * 2) {
            return kAudioHardwareBadPropertySizeError;
          }
          AudioObjectID owned[2] = {kObjectIDStreamInput, kObjectIDStreamOutput};
          std::memcpy(out_data, owned, sizeof(owned));
          if (out_data_size != nullptr) {
            *out_data_size = sizeof(owned);
          }
          return kAudioHardwareNoError;
        }
        case kAudioObjectPropertyControlList:
          if (out_data_size != nullptr) {
            *out_data_size = 0;
          }
          return kAudioHardwareNoError;
        case kAudioDevicePropertyDeviceUID:
          return WriteCStringAsCFString(in_data_size, out_data_size, out_data, kDeviceUID);
        case kAudioDevicePropertyModelUID:
          return WriteCStringAsCFString(in_data_size, out_data_size, out_data, kModelUID);
        case kAudioDevicePropertyTransportType:
          return WriteSingleValue(
              in_data_size, out_data_size, out_data, UInt32{kAudioDeviceTransportTypeVirtual});
        case kAudioDevicePropertyStreams: {
          if (out_data == nullptr) {
            return kAudioHardwareIllegalOperationError;
          }
          if (in_address->mScope == kAudioObjectPropertyScopeInput) {
            return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDStreamInput});
          }
          if (in_address->mScope == kAudioObjectPropertyScopeOutput) {
            return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDStreamOutput});
          }
          if (in_data_size < sizeof(AudioObjectID) * 2) {
            return kAudioHardwareBadPropertySizeError;
          }
          AudioObjectID streams[2] = {kObjectIDStreamInput, kObjectIDStreamOutput};
          std::memcpy(out_data, streams, sizeof(streams));
          if (out_data_size != nullptr) {
            *out_data_size = sizeof(streams);
          }
          return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyStreamConfiguration: {
          const UInt32 required_size = static_cast<UInt32>(offsetof(AudioBufferList, mBuffers) +
                                                           sizeof(AudioBuffer));
          if (in_data_size < required_size || out_data == nullptr) {
            return kAudioHardwareBadPropertySizeError;
          }
          auto* abl = reinterpret_cast<AudioBufferList*>(out_data);
          abl->mNumberBuffers = 1;
          abl->mBuffers[0].mNumberChannels = kChannelCount;
          abl->mBuffers[0].mDataByteSize = 0;
          abl->mBuffers[0].mData = nullptr;
          if (out_data_size != nullptr) {
            *out_data_size = required_size;
          }
          return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyNominalSampleRate:
          return WriteSingleValue(
              in_data_size, out_data_size, out_data, g_sample_rate.load(std::memory_order_relaxed));
        case kAudioDevicePropertyAvailableNominalSampleRates: {
          AudioValueRange range{};
          const Float64 rate = g_sample_rate.load(std::memory_order_relaxed);
          range.mMinimum = rate;
          range.mMaximum = rate;
          return WriteSingleValue(in_data_size, out_data_size, out_data, range);
        }
        case kAudioDevicePropertyBufferFrameSize:
          return WriteSingleValue(
              in_data_size, out_data_size, out_data, g_buffer_frame_size.load(std::memory_order_relaxed));
        case kAudioDevicePropertyBufferFrameSizeRange: {
          AudioValueRange range{};
          range.mMinimum = 64;
          range.mMaximum = 4096;
          return WriteSingleValue(in_data_size, out_data_size, out_data, range);
        }
        case kAudioDevicePropertySafetyOffset:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{0});
        case kAudioDevicePropertyLatency:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{0});
        case kAudioDevicePropertyZeroTimeStampPeriod:
          return WriteSingleValue(
              in_data_size, out_data_size, out_data, g_buffer_frame_size.load(std::memory_order_relaxed));
        case kAudioDevicePropertyPreferredChannelsForStereo: {
          if (in_data_size < sizeof(UInt32) * 2 || out_data == nullptr) {
            return kAudioHardwareBadPropertySizeError;
          }
          UInt32 channels[2] = {1, 2};
          std::memcpy(out_data, channels, sizeof(channels));
          if (out_data_size != nullptr) {
            *out_data_size = sizeof(channels);
          }
          return kAudioHardwareNoError;
        }
        case kAudioDevicePropertyDeviceIsAlive:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{1});
        case kAudioDevicePropertyDeviceIsRunning: {
          const UInt32 running = g_io_client_count.load(std::memory_order_relaxed) > 0 ? 1 : 0;
          return WriteSingleValue(in_data_size, out_data_size, out_data, running);
        }
        case kAudioDevicePropertyClockDomain:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{0});
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{1});
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{1});
        case kAudioDevicePropertyRelatedDevices:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDDevice});
        case kAudioDevicePropertyClockIsStable:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{1});
        case kAudioDevicePropertyIsHidden:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{0});
        default:
          return kAudioHardwareUnknownPropertyError;
      }

    case kObjectIDStreamInput:
    case kObjectIDStreamOutput:
      switch (in_address->mSelector) {
        case kAudioObjectPropertyBaseClass:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioClassID{kAudioObjectClassID});
        case kAudioObjectPropertyClass:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioClassID{kAudioStreamClassID});
        case kAudioObjectPropertyOwner:
          return WriteSingleValue(in_data_size, out_data_size, out_data, AudioObjectID{kObjectIDDevice});
        case kAudioObjectPropertyName:
          return WriteCStringAsCFString(
              in_data_size,
              out_data_size,
              out_data,
              in_object_id == kObjectIDStreamInput ? kInputStreamName : kOutputStreamName);
        case kAudioStreamPropertyDirection:
          return WriteSingleValue(in_data_size,
                                  out_data_size,
                                  out_data,
                                  UInt32{static_cast<UInt32>(in_object_id == kObjectIDStreamInput ? 1 : 0)});
        case kAudioStreamPropertyTerminalType:
          return WriteSingleValue(in_data_size,
                                  out_data_size,
                                  out_data,
                                  UInt32{in_object_id == kObjectIDStreamInput ? kAudioStreamTerminalTypeMicrophone
                                                                               : kAudioStreamTerminalTypeSpeaker});
        case kAudioStreamPropertyStartingChannel:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{1});
        case kAudioStreamPropertyLatency:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{0});
        case kAudioStreamPropertyIsActive:
          return WriteSingleValue(in_data_size, out_data_size, out_data, UInt32{1});
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
          const AudioStreamBasicDescription asbd =
              MakeStreamFormat(g_sample_rate.load(std::memory_order_relaxed));
          return WriteSingleValue(in_data_size, out_data_size, out_data, asbd);
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
          AudioStreamRangedDescription ranged{};
          ranged.mFormat = MakeStreamFormat(g_sample_rate.load(std::memory_order_relaxed));
          ranged.mSampleRateRange.mMinimum = ranged.mFormat.mSampleRate;
          ranged.mSampleRateRange.mMaximum = ranged.mFormat.mSampleRate;
          return WriteSingleValue(in_data_size, out_data_size, out_data, ranged);
        }
        default:
          return kAudioHardwareUnknownPropertyError;
      }
    default:
      return kAudioHardwareBadObjectError;
  }
}

OSStatus DriverSetPropertyData(AudioServerPlugInDriverRef /*in_driver*/,
                               AudioObjectID in_object_id,
                               pid_t /*in_client_process_id*/,
                               const AudioObjectPropertyAddress* in_address,
                               UInt32 /*in_qualifier_data_size*/,
                               const void* /*in_qualifier_data*/,
                               UInt32 in_data_size,
                               const void* in_data) {
  if (in_address == nullptr || in_data == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }
  if (!IsKnownObject(in_object_id)) {
    return kAudioHardwareBadObjectError;
  }

  if (in_object_id == kObjectIDDevice && in_address->mSelector == kAudioDevicePropertyNominalSampleRate) {
    if (in_data_size < sizeof(Float64)) {
      return kAudioHardwareBadPropertySizeError;
    }
    const Float64 requested_rate = *reinterpret_cast<const Float64*>(in_data);
    if (requested_rate <= 0.0) {
      return kAudioHardwareIllegalOperationError;
    }
    g_sample_rate.store(requested_rate, std::memory_order_relaxed);

    AudioObjectPropertyAddress changed[3] = {
        {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    NotifyPropertiesChanged(kObjectIDDevice, 1, &changed[0]);
    NotifyPropertiesChanged(kObjectIDStreamInput, 2, &changed[1]);
    NotifyPropertiesChanged(kObjectIDStreamOutput, 2, &changed[1]);
    return kAudioHardwareNoError;
  }

  if (in_object_id == kObjectIDDevice && in_address->mSelector == kAudioDevicePropertyBufferFrameSize) {
    if (in_data_size < sizeof(UInt32)) {
      return kAudioHardwareBadPropertySizeError;
    }
    const UInt32 requested_frames = *reinterpret_cast<const UInt32*>(in_data);
    if (requested_frames < 64 || requested_frames > 4096) {
      return kAudioHardwareIllegalOperationError;
    }
    g_buffer_frame_size.store(requested_frames, std::memory_order_relaxed);
    AudioObjectPropertyAddress changed = {kAudioDevicePropertyBufferFrameSize,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    NotifyPropertiesChanged(kObjectIDDevice, 1, &changed);
    return kAudioHardwareNoError;
  }

  if ((in_object_id == kObjectIDStreamInput || in_object_id == kObjectIDStreamOutput) &&
      (in_address->mSelector == kAudioStreamPropertyVirtualFormat ||
       in_address->mSelector == kAudioStreamPropertyPhysicalFormat)) {
    if (in_data_size < sizeof(AudioStreamBasicDescription)) {
      return kAudioHardwareBadPropertySizeError;
    }
    const auto* asbd = reinterpret_cast<const AudioStreamBasicDescription*>(in_data);
    if (asbd->mSampleRate <= 0.0 || asbd->mChannelsPerFrame != kChannelCount ||
        asbd->mFormatID != kAudioFormatLinearPCM) {
      return kAudioHardwareIllegalOperationError;
    }
    g_sample_rate.store(asbd->mSampleRate, std::memory_order_relaxed);
    AudioObjectPropertyAddress changed = {in_address->mSelector,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    NotifyPropertiesChanged(in_object_id, 1, &changed);
    return kAudioHardwareNoError;
  }

  return kAudioHardwareUnsupportedOperationError;
}

OSStatus DriverStartIO(AudioServerPlugInDriverRef /*in_driver*/,
                       AudioObjectID in_device_object_id,
                       UInt32 /*in_client_id*/) {
  if (in_device_object_id != kObjectIDDevice) {
    return kAudioHardwareBadObjectError;
  }
  const UInt32 previous = g_io_client_count.fetch_add(1, std::memory_order_acq_rel);
  if (previous == 0) {
    g_anchor_host_time.store(AudioGetCurrentHostTime(), std::memory_order_relaxed);
    g_anchor_sample_time.store(0.0, std::memory_order_relaxed);
    g_clock_seed.fetch_add(1, std::memory_order_relaxed);
  }
  return kAudioHardwareNoError;
}

OSStatus DriverStopIO(AudioServerPlugInDriverRef /*in_driver*/,
                      AudioObjectID in_device_object_id,
                      UInt32 /*in_client_id*/) {
  if (in_device_object_id != kObjectIDDevice) {
    return kAudioHardwareBadObjectError;
  }
  const UInt32 current = g_io_client_count.load(std::memory_order_relaxed);
  if (current > 0) {
    g_io_client_count.fetch_sub(1, std::memory_order_acq_rel);
  }
  return kAudioHardwareNoError;
}

OSStatus DriverGetZeroTimeStamp(AudioServerPlugInDriverRef /*in_driver*/,
                                AudioObjectID in_device_object_id,
                                UInt32 /*in_client_id*/,
                                Float64* out_sample_time,
                                UInt64* out_host_time,
                                UInt64* out_seed) {
  if (in_device_object_id != kObjectIDDevice) {
    return kAudioHardwareBadObjectError;
  }
  if (out_sample_time == nullptr || out_host_time == nullptr || out_seed == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }

  const UInt64 now_host = AudioGetCurrentHostTime();
  UInt64 anchor = g_anchor_host_time.load(std::memory_order_relaxed);
  if (anchor == 0) {
    anchor = now_host;
    g_anchor_host_time.store(anchor, std::memory_order_relaxed);
  }

  const Float64 host_freq = AudioGetHostClockFrequency();
  const Float64 sample_rate = g_sample_rate.load(std::memory_order_relaxed);
  const UInt32 buffer_frames = g_buffer_frame_size.load(std::memory_order_relaxed);

  const Float64 elapsed_seconds = static_cast<Float64>(now_host - anchor) / host_freq;
  const Float64 elapsed_samples = elapsed_seconds * sample_rate;

  const UInt64 num_periods = static_cast<UInt64>(elapsed_samples) / buffer_frames;
  const Float64 quantized_sample_time = static_cast<Float64>(num_periods * buffer_frames);
  const Float64 quantized_host_seconds = quantized_sample_time / sample_rate;
  const UInt64 quantized_host_time = anchor + static_cast<UInt64>(quantized_host_seconds * host_freq);

  *out_sample_time = quantized_sample_time;
  *out_host_time = quantized_host_time;
  *out_seed = g_clock_seed.load(std::memory_order_relaxed);
  return kAudioHardwareNoError;
}

OSStatus DriverWillDoIOOperation(AudioServerPlugInDriverRef /*in_driver*/,
                                 AudioObjectID in_device_object_id,
                                 UInt32 /*in_client_id*/,
                                 UInt32 in_operation_id,
                                 Boolean* out_will_do,
                                 Boolean* out_will_do_in_place) {
  if (in_device_object_id != kObjectIDDevice) {
    return kAudioHardwareBadObjectError;
  }
  if (out_will_do == nullptr || out_will_do_in_place == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }

  const bool supported = in_operation_id == kAudioServerPlugInIOOperationReadInput ||
                         in_operation_id == kAudioServerPlugInIOOperationWriteMix;
  *out_will_do = supported;
  *out_will_do_in_place = supported;
  return kAudioHardwareNoError;
}

OSStatus DriverBeginIOOperation(AudioServerPlugInDriverRef /*in_driver*/,
                                AudioObjectID in_device_object_id,
                                UInt32 /*in_client_id*/,
                                UInt32 /*in_operation_id*/,
                                UInt32 /*in_io_buffer_frame_size*/,
                                const AudioServerPlugInIOCycleInfo* /*in_io_cycle_info*/) {
  return in_device_object_id == kObjectIDDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

OSStatus DriverDoIOOperation(AudioServerPlugInDriverRef /*in_driver*/,
                             AudioObjectID in_device_object_id,
                             AudioObjectID /*in_stream_object_id*/,
                             UInt32 /*in_client_id*/,
                             UInt32 in_operation_id,
                             UInt32 in_io_buffer_frame_size,
                             const AudioServerPlugInIOCycleInfo* /*in_io_cycle_info*/,
                             void* io_main_buffer,
                             void* /*io_secondary_buffer*/) {
  if (in_device_object_id != kObjectIDDevice) {
    return kAudioHardwareBadObjectError;
  }

  if (in_operation_id != kAudioServerPlugInIOOperationReadInput &&
      in_operation_id != kAudioServerPlugInIOOperationWriteMix) {
    return kAudioHardwareUnsupportedOperationError;
  }
  if (io_main_buffer == nullptr) {
    return kAudioHardwareIllegalOperationError;
  }

  std::lock_guard<std::mutex> lock(g_ring_mutex);
  auto* frames = reinterpret_cast<float*>(io_main_buffer);
  const size_t frame_count = static_cast<size_t>(in_io_buffer_frame_size);

  if (in_operation_id == kAudioServerPlugInIOOperationReadInput) {
    const size_t got = g_mic_feed_ring.Read(frames, frame_count);
    if (got < frame_count) {
      const size_t start = got * kChannelCount;
      const size_t count = (frame_count - got) * kChannelCount;
      std::memset(frames + start, 0, sizeof(float) * count);
    }
    return kAudioHardwareNoError;
  }

  (void)g_speaker_tap_ring.Write(frames, frame_count);
  return kAudioHardwareNoError;
}

OSStatus DriverEndIOOperation(AudioServerPlugInDriverRef /*in_driver*/,
                              AudioObjectID in_device_object_id,
                              UInt32 /*in_client_id*/,
                              UInt32 /*in_operation_id*/,
                              UInt32 /*in_io_buffer_frame_size*/,
                              const AudioServerPlugInIOCycleInfo* /*in_io_cycle_info*/) {
  return in_device_object_id == kObjectIDDevice ? kAudioHardwareNoError : kAudioHardwareBadObjectError;
}

}  // namespace

extern "C" void* VirtualAudioDriverFactory(CFAllocatorRef /*in_allocator*/,
                                           CFUUIDRef in_requested_type_uuid) {
  if (in_requested_type_uuid == nullptr) {
    return nullptr;
  }
  if (CFEqual(in_requested_type_uuid, kAudioServerPlugInTypeUUID)) {
    DriverAddRef(g_driver_ref);
    return g_driver_ref;
  }
  return nullptr;
}
