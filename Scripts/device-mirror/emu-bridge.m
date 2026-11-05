// One Android emulator's screen as H.264 on stdout, its touches from stdin: the same
// protocol as sim-bridge, over the emulator's public gRPC API. No gRPC library: HTTP/2 without TLS
// is a few frames, and only what these two calls need is here (headers of responses are not read).
//
//   emu-bridge <gRPC port>      token, if any, in the environment's EMU_TOKEN
//   stdout: big-endian u32 length, then u8 isKey; if key: u16 + SPS, u16 + PPS; then AVCC NAL units.
//   stdin:  lines "d x y", "m x y", "u x y" from 0 to 1, top left origin; "k" asks a key frame.
#import <Accelerate/Accelerate.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <arpa/inet.h>
#import <netinet/tcp.h>
#import <pthread.h>
#import <sys/socket.h>
#import <unistd.h>

static const char *service = "/android.emulation.control.EmulatorController/";
static int sock = -1;
static pthread_mutex_t writing = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t encoding = PTHREAD_MUTEX_INITIALIZER;
static uint32_t nextStream = 1;
static volatile int nativeWidth = 0, nativeHeight = 0;

static void writeAll(int fd, const void *bytes, size_t count) {
  const uint8_t *cursor = bytes;
  while (count > 0) {
    ssize_t written = write(fd, cursor, count);
    if (written <= 0) exit(0);
    cursor += written;
    count -= (size_t)written;
  }
}

static void readAll(void *bytes, size_t count) {
  uint8_t *cursor = bytes;
  while (count > 0) {
    ssize_t got = read(sock, cursor, count);
    if (got <= 0) exit(0);
    cursor += got;
    count -= (size_t)got;
  }
}

// MARK: - HTTP/2

static void frame(uint8_t type, uint8_t flags, uint32_t stream, const void *body, uint32_t length) {
  uint8_t header[9] = {length >> 16, length >> 8, length, type, flags,
                       stream >> 24, stream >> 16, stream >> 8, stream};
  pthread_mutex_lock(&writing);
  writeAll(sock, header, 9);
  if (length) writeAll(sock, body, length);
  pthread_mutex_unlock(&writing);
}

static void windowUpdate(uint32_t stream, uint32_t increment) {
  uint32_t big = CFSwapInt32HostToBig(increment);
  frame(8, 0, stream, &big, 4);
}

static void literal(NSMutableData *block, const char *name, const char *value) {
  uint8_t zero = 0, nameLength = (uint8_t)strlen(name), valueLength = (uint8_t)strlen(value);
  [block appendBytes:&zero length:1];
  [block appendBytes:&nameLength length:1];
  [block appendBytes:name length:nameLength];
  [block appendBytes:&valueLength length:1];
  [block appendBytes:value length:valueLength];
}

/// A call whose whole request is `message`. Returns its stream.
static uint32_t call(const char *method, NSData *message) {
  NSMutableData *block = [NSMutableData data];
  literal(block, ":method", "POST");
  literal(block, ":scheme", "http");
  literal(block, ":path", [NSString stringWithFormat:@"%s%s", service, method].UTF8String);
  literal(block, ":authority", "localhost");
  literal(block, "content-type", "application/grpc");
  literal(block, "te", "trailers");
  const char *token = getenv("EMU_TOKEN");
  if (token && *token) {
    literal(block, "authorization", [NSString stringWithFormat:@"Bearer %s", token].UTF8String);
  }
  NSMutableData *body = [NSMutableData dataWithLength:5];
  uint32_t length = CFSwapInt32HostToBig((uint32_t)message.length);
  memcpy((uint8_t *)body.mutableBytes + 1, &length, 4);
  [body appendData:message];
  static pthread_mutex_t calling = PTHREAD_MUTEX_INITIALIZER;
  pthread_mutex_lock(&calling);
  uint32_t stream = nextStream;
  nextStream += 2;
  frame(1, 4, stream, block.bytes, (uint32_t)block.length);
  frame(0, 1, stream, body.bytes, (uint32_t)body.length);
  pthread_mutex_unlock(&calling);
  return stream;
}

// MARK: - Protobuf

static void varint(NSMutableData *data, uint64_t value) {
  do {
    uint8_t byte = value & 0x7f;
    value >>= 7;
    if (value) byte |= 0x80;
    [data appendBytes:&byte length:1];
  } while (value);
}

static void field(NSMutableData *data, int number, uint64_t value) {
  varint(data, (uint64_t)number << 3);
  varint(data, value);
}

static bool readVarint(const uint8_t **cursor, const uint8_t *end, uint64_t *value) {
  *value = 0;
  for (int shift = 0; *cursor < end && shift < 64; shift += 7) {
    uint8_t byte = *(*cursor)++;
    *value |= (uint64_t)(byte & 0x7f) << shift;
    if (!(byte & 0x80)) return true;
  }
  return false;
}

/// An `Image`: its format's width and height, and its pixels.
static bool parseImage(const uint8_t *cursor, const uint8_t *end, int *width, int *height,
                       const uint8_t **pixels, size_t *size) {
  uint64_t key, value;
  while (cursor < end && readVarint(&cursor, end, &key)) {
    int number = (int)(key >> 3), wire = key & 7;
    if (wire == 0) {
      if (!readVarint(&cursor, end, &value)) return false;
    } else if (wire == 2) {
      if (!readVarint(&cursor, end, &value) || value > (uint64_t)(end - cursor)) return false;
      if (number == 1) {
        const uint8_t *inner = cursor, *innerEnd = cursor + value;
        uint64_t innerKey, innerValue;
        while (inner < innerEnd && readVarint(&inner, innerEnd, &innerKey)) {
          if ((innerKey & 7) == 2) {
            if (!readVarint(&inner, innerEnd, &innerValue)) break;
            inner += innerValue;
          } else if ((innerKey & 7) == 0) {
            if (!readVarint(&inner, innerEnd, &innerValue)) break;
            if (innerKey >> 3 == 3) *width = (int)innerValue;
            if (innerKey >> 3 == 4) *height = (int)innerValue;
          } else {
            break;
          }
        }
      } else if (number == 4) {
        *pixels = cursor;
        *size = (size_t)value;
      }
      cursor += value;
    } else {
      return false;
    }
  }
  return *pixels != NULL;
}

// MARK: - Video

static void encoded(void *unused, void *frameInfo, OSStatus status, VTEncodeInfoFlags flags,
                    CMSampleBufferRef sample) {
  if (status != noErr || !sample) return;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, false);
  bool isKey = true;
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef first = CFArrayGetValueAtIndex(attachments, 0);
    isKey = !CFDictionaryContainsKey(first, kCMSampleAttachmentKey_NotSync);
  }
  NSMutableData *payload = [NSMutableData data];
  uint8_t key = isKey;
  [payload appendBytes:&key length:1];
  if (isKey) {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sample);
    for (size_t index = 0; index < 2; index++) {
      const uint8_t *set = NULL;
      size_t size = 0;
      CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, index, &set, &size, NULL, NULL);
      uint16_t length = CFSwapInt16HostToBig((uint16_t)size);
      [payload appendBytes:&length length:2];
      [payload appendBytes:set length:size];
    }
  }
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
  size_t total = 0;
  char *bytes = NULL;
  CMBlockBufferGetDataPointer(block, 0, NULL, &total, &bytes);
  [payload appendBytes:bytes length:total];
  uint32_t length = CFSwapInt32HostToBig((uint32_t)payload.length);
  writeAll(1, &length, 4);
  writeAll(1, payload.bytes, payload.length);
}

static VTCompressionSessionRef encoder = NULL;
static CVPixelBufferRef lastFrame = NULL;
static int encoderWidth = 0, encoderHeight = 0;
static int64_t frameIndex = 0;

static void encodeLast(bool forceKey) {
  if (!encoder || !lastFrame) return;
  NSDictionary *properties = forceKey ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES} : nil;
  VTCompressionSessionEncodeFrame(encoder, lastFrame, CMTimeMake(frameIndex++, 60), kCMTimeInvalid,
                                  (__bridge CFDictionaryRef)properties, NULL, NULL);
}

static void show(const uint8_t *pixels, size_t size, int width, int height) {
  if (size < (size_t)width * height * 4) return;
  pthread_mutex_lock(&encoding);
  bool isNew = width != encoderWidth || height != encoderHeight;
  if (isNew) {
    if (encoder) {
      VTCompressionSessionInvalidate(encoder);
      CFRelease(encoder);
    }
    VTCompressionSessionCreate(
        NULL, width, height, kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)@{
          (id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES
        },
        NULL, NULL, encoded, NULL, &encoder);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef) @6000000);
    VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef) @240);
    encoderWidth = width;
    encoderHeight = height;
    if (lastFrame) CVPixelBufferRelease(lastFrame);
    lastFrame = NULL;
  }
  // A buffer of its own for each frame: the encoder may still hold the last one.
  CVPixelBufferRef buffer = NULL;
  CVPixelBufferCreate(NULL, width, height, kCVPixelFormatType_32BGRA,
                      (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}},
                      &buffer);
  if (buffer) {
    CVPixelBufferLockBaseAddress(buffer, 0);
    vImage_Buffer source = {(void *)pixels, (vImagePixelCount)height, (vImagePixelCount)width,
                            (size_t)width * 4};
    vImage_Buffer target = {CVPixelBufferGetBaseAddress(buffer), (vImagePixelCount)height,
                            (vImagePixelCount)width, CVPixelBufferGetBytesPerRow(buffer)};
    const uint8_t rgbaToBgra[4] = {2, 1, 0, 3};
    vImagePermuteChannels_ARGB8888(&source, &target, rgbaToBgra, kvImageNoFlags);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    if (lastFrame) CVPixelBufferRelease(lastFrame);
    lastFrame = buffer;
    encodeLast(isNew);
  }
  pthread_mutex_unlock(&encoding);
}

// MARK: - Touches

static void touch(char phase, double x, double y) {
  if (!nativeWidth) return;
  NSMutableData *one = [NSMutableData data];
  field(one, 1, (uint64_t)(int64_t)(x * nativeWidth));
  field(one, 2, (uint64_t)(int64_t)(y * nativeHeight));
  field(one, 3, 1);
  // Pressure is what tells a finger down from a finger up.
  field(one, 4, phase == 'u' ? 0 : 1024);
  NSMutableData *event = [NSMutableData data];
  varint(event, 1 << 3 | 2);
  varint(event, one.length);
  [event appendData:one];
  call("sendTouch", event);
}

static void *readTouches(void *unused) {
  char line[64];
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == 'k') {
      pthread_mutex_lock(&encoding);
      encodeLast(true);
      pthread_mutex_unlock(&encoding);
      continue;
    }
    char phase;
    double x, y;
    if (sscanf(line, "%c %lf %lf", &phase, &x, &y) == 3) touch(phase, x, y);
  }
  exit(0);
}

// MARK: - Main

static uint32_t askFrames(int width, int height) {
  NSMutableData *format = [NSMutableData data];
  field(format, 1, 1);  // RGBA8888
  if (width) {
    field(format, 3, (uint64_t)width);
    field(format, 4, (uint64_t)height);
  }
  return call("streamScreenshot", format);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 2;
    sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons((uint16_t)atoi(argv[1]))};
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(sock, (struct sockaddr *)&address, sizeof address) != 0) {
      fprintf(stderr, "emu-bridge: no emulator on port %s\n", argv[1]);
      return 1;
    }
    int yes = 1;
    setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes);
    writeAll(sock, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", 24);
    const uint8_t settings[] = {0, 2, 0, 0, 0, 0,             // No pushes.
                                0, 4, 0x40, 0, 0, 0,          // A window of 1 GB.
                                0, 5, 0, 0x10, 0, 0};         // Frames of 1 MB.
    frame(4, 0, 0, settings, sizeof settings);
    windowUpdate(0, 0x40000000);

    // Once at the screen's own size, which touches are counted in, then at the size to send.
    uint32_t video = askFrames(0, 0);
    pthread_t touches;
    NSMutableData *message = [NSMutableData data];
    size_t bodySize = 1 << 21;
    uint8_t *body = malloc(bodySize);
    for (;;) {
      uint8_t header[9];
      readAll(header, 9);
      uint32_t length = (uint32_t)header[0] << 16 | (uint32_t)header[1] << 8 | header[2];
      uint8_t type = header[3], flags = header[4];
      uint32_t stream = ((uint32_t)header[5] << 24 | (uint32_t)header[6] << 16 |
                         (uint32_t)header[7] << 8 | header[8]) & 0x7fffffff;
      if (length > bodySize) {
        bodySize = length;
        body = realloc(body, bodySize);
      }
      if (length) readAll(body, length);
      if (type == 4 && !(flags & 1)) {
        frame(4, 1, 0, NULL, 0);
      } else if (type == 6 && !(flags & 1)) {
        frame(6, 1, 0, body, length);
      } else if (type == 7) {
        fprintf(stderr, "emu-bridge: the emulator closed the connection\n");
        return 1;
      } else if (type == 0 && length) {
        windowUpdate(0, length);
        if (stream != video) continue;
        windowUpdate(stream, length);
        [message appendBytes:body length:length];
        while (message.length >= 5) {
          const uint8_t *bytes = message.bytes;
          uint32_t size = (uint32_t)bytes[1] << 24 | (uint32_t)bytes[2] << 16 |
                          (uint32_t)bytes[3] << 8 | bytes[4];
          if (message.length < 5 + (size_t)size) break;
          int width = 0, height = 0;
          const uint8_t *pixels = NULL;
          size_t count = 0;
          if (parseImage(bytes + 5, bytes + 5 + size, &width, &height, &pixels, &count)) {
            if (!nativeWidth) {
              nativeHeight = height;
              nativeWidth = width;
              pthread_create(&touches, NULL, readTouches, NULL);
              // Enough to read on a phone, even numbers for the encoder.
              double scale = width > 720 ? 720.0 / width : 1;
              uint32_t reset = 0;
              frame(3, 0, video, &reset, 4);
              [message setLength:0];
              video = askFrames((int)(width * scale) & ~1, (int)(height * scale) & ~1);
              break;
            }
            // Every frame: the emulator sends one per change, and the last must not be lost.
            show(pixels, count, width, height);
          }
          [message replaceBytesInRange:NSMakeRange(0, 5 + (size_t)size) withBytes:NULL length:0];
        }
      } else if (type == 1 && stream == video && (flags & 1)) {
        fprintf(stderr, "emu-bridge: the emulator refused the stream\n");
        return 1;
      } else if (type == 3 && stream == video) {
        fprintf(stderr, "emu-bridge: the stream was reset\n");
        return 1;
      }
    }
  }
}
