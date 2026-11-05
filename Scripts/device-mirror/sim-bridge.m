// One simulator's screen as H.264 on stdout, its touches from stdin; it holds Apple's
// private frameworks so that the application never loads them, and leaves when stdin closes.
//
//   sim-bridge <UDID>
//   stdout: big-endian u32 length, then u8 isKey; if key: u16 + SPS, u16 + PPS; then AVCC NAL units.
//   stdin:  lines "d x y", "m x y", "u x y", coordinates from 0 to 1, top left origin.
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <VideoToolbox/VideoToolbox.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>
#import <objc/message.h>

typedef void *(*MakeParent)(void *, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                            double, double, double, double, double, bool, bool, uint32_t);
typedef void *(*MakeFinger)(void *, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double,
                            double, double, bool, bool, uint32_t);
typedef void (*Append)(void *, void *, uint32_t);
typedef void *(*Wrap)(void *);
typedef void *(*MakeService)(void);

static NSString *udid;
static id device;
static id hid;
static void *simulatorKit;
static MakeParent makeParent;
static MakeFinger makeFinger;
static Append appendEvent;
static Wrap wrap;
static _Atomic bool repairing = false;
static bool inputReady = false;

static void writeAll(const void *bytes, size_t count) {
  const char *cursor = bytes;
  while (count > 0) {
    ssize_t written = write(STDOUT_FILENO, cursor, count);
    if (written <= 0) exit(0);
    cursor += written;
    count -= (size_t)written;
  }
}

static void encoded(void *unused, void *frame, OSStatus status, VTEncodeInfoFlags flags,
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
  writeAll(&length, 4);
  writeAll(payload.bytes, payload.length);
}

static IOSurfaceRef currentSurface(void) {
  IOSurfaceRef best = NULL;
  id io = [device valueForKey:@"io"];
  for (id port in [io valueForKey:@"ioPorts"]) {
    id descriptor = [port performSelector:@selector(descriptor)];
    if (![descriptor respondsToSelector:@selector(framebufferSurface)]) continue;
    IOSurfaceRef surface =
        (__bridge IOSurfaceRef)[descriptor performSelector:@selector(framebufferSurface)];
    if (surface && (!best || IOSurfaceGetWidth(surface) > IOSurfaceGetWidth(best))) best = surface;
  }
  if (best) CFRetain(best);
  return best;
}

static void sendMessage(void *message) {
  // A nil queue or completion crashes SimulatorKit.
  ((void (*)(id, SEL, void *, BOOL, id, id))objc_msgSend)(
      hid, NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:"),
      message, YES, dispatch_get_global_queue(0, 0), ^(NSError *error) {
      });
}

static NSString *guest(NSArray<NSString *> *arguments) {
  NSTask *task = [NSTask new];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
  NSMutableArray *all = [@[ @"simctl", @"spawn", udid ] mutableCopy];
  [all addObjectsFromArray:arguments];
  task.arguments = all;
  NSPipe *output = [NSPipe pipe];
  task.standardOutput = output;
  task.standardError = [NSFileHandle fileHandleWithNullDevice];
  [task launchAndReturnError:nil];
  NSData *data = [output.fileHandleForReading readDataToEndOfFile];
  [task waitUntilExit];
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

// Device Hub's dtuhidd disconnects the touch service: messages leave without error and land
// nowhere. The order matters, and restarting backboardd shows, so only on a first touch, if needed.
static void prepareInput(void) {
  NSString *state = guest(@[ @"notifyutil", @"-g", @"com.apple.coredevice.dtuhidd.active" ]);
  if ([state containsString:@" 1"]) {
    fprintf(stderr, "sim-bridge: reclaiming the touch service from Device Hub\n");
    guest(@[ @"notifyutil", @"-s", @"com.apple.coredevice.dtuhidd.active", @"0" ]);
    guest(@[ @"launchctl", @"kickstart", @"-k", @"system/com.apple.backboardd" ]);
    sleep(4);
  }
  NSError *error = nil;
  hid = ((id(*)(id, SEL, id, NSError **))objc_msgSend)(
      [objc_getClass("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") alloc],
      NSSelectorFromString(@"initWithDevice:error:"), device, &error);
  if (!hid) fprintf(stderr, "sim-bridge: no HID client: %s\n", error.description.UTF8String);
  sendMessage(((MakeService)dlsym(simulatorKit, "IndigoHIDMessageToCreatePointerService"))());
  sendMessage(((MakeService)dlsym(simulatorKit, "IndigoHIDMessageToCreateMouseService"))());
  usleep(100000);
  inputReady = true;
}

static bool touchFromBottomEdge = false;

static void touch(char phase, double x, double y) {
  if (phase == 'd') touchFromBottomEdge = y > 0.975;
  bool down = phase != 'u';
  uint32_t mask = down ? 7 : 6;
  uint64_t now = mach_absolute_time();
  void *parent = makeParent(NULL, now, 2, 0, 7, mask, 0, x, y, 0, 0, 0, down, down, 0);
  void *finger = makeFinger(NULL, now, 0, 7, mask, x, y, 0, 0, 0, down, down, 0);
  appendEvent(parent, finger, 0);
  char *message = wrap(parent);
  CFRelease(finger);
  CFRelease(parent);
  if (!message) return;
  size_t size = malloc_size(message);
  *(uint32_t *)(message + 0x6c) = 0x32;
  if (size >= 0x110) *(uint32_t *)(message + 0x10c) = 0x32;
  // The home indicator's gesture: a touch that began on the bottom edge.
  uint8_t present = touchFromBottomEdge ? 0x04 : 0, edge = touchFromBottomEdge ? 0x01 : 0;
  message[0x3a] = present;
  message[0x3b] = edge;
  if (size >= 0xdc) {
    message[0xda] = present;
    message[0xdb] = edge;
  }
  sendMessage(message);
}

// Asked when late frames were dropped: decoding needs a key frame, even on a still screen.
static volatile bool keyRequested = false;

static void readTouches(void) {
  char line[64];
  bool lostTouch = true;
  while (fgets(line, sizeof line, stdin)) {
    if (line[0] == 'k') {
      keyRequested = true;
      continue;
    }
    char phase;
    double x, y;
    if (sscanf(line, "%c %lf %lf", &phase, &x, &y) != 3) continue;
    if (repairing) {
      lostTouch = true;
      continue;
    }
    if (!inputReady) {
      repairing = true;
      dispatch_async(dispatch_get_global_queue(0, 0), ^{
        prepareInput();
        repairing = false;
      });
      lostTouch = true;
      continue;
    }
    // What was under the finger while the input came back is not the start of a gesture.
    if (lostTouch && phase != 'd') continue;
    lostTouch = false;
    touch(phase, x, y);
  }
  exit(0);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 2) return 2;
    udid = @(argv[1]);
    signal(SIGPIPE, SIG_DFL);
    dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    simulatorKit = dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/"
                          "SimulatorKit.framework/Versions/A/SimulatorKit", RTLD_NOW);
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!simulatorKit || !iokit) {
      fprintf(stderr, "sim-bridge: %s\n", dlerror());
      return 3;
    }
    makeParent = dlsym(iokit, "IOHIDEventCreateDigitizerEvent");
    makeFinger = dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
    appendEvent = dlsym(iokit, "IOHIDEventAppendEvent");
    wrap = dlsym(simulatorKit, "IndigoHIDMessageForTrackpadEventFromHIDEventRef");

    id context = ((id(*)(id, SEL, id, id *))objc_msgSend)(
        objc_getClass("SimServiceContext"),
        NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),
        @"/Applications/Xcode.app/Contents/Developer", nil);
    id set = ((id(*)(id, SEL, id *))objc_msgSend)(
        context, NSSelectorFromString(@"defaultDeviceSetWithError:"), nil);
    for (id candidate in [set valueForKey:@"devices"])
      if ([[[candidate valueForKey:@"UDID"] UUIDString] isEqual:udid]) device = candidate;
    if (!device) {
      fprintf(stderr, "sim-bridge: no device %s\n", argv[1]);
      return 4;
    }
    dispatch_async(dispatch_queue_create("touches", DISPATCH_QUEUE_SERIAL), ^{
      readTouches();
    });

    IOSurfaceRef surface = NULL;
    VTCompressionSessionRef encoder = NULL;
    size_t width = 0, height = 0;
    uint32_t seed = 0;
    int64_t index = 0;
    uint64_t lastLookup = 0, lastFrame = 0;
    bool forceKey = true;
    mach_timebase_info_data_t base;
    mach_timebase_info(&base);
    for (;;) {
      @autoreleasepool {
        uint64_t now = mach_absolute_time() * base.numer / base.denom;
        // backboardd's restart, a rotation: another surface.
        if (now - lastLookup > 1000000000ull) {
          lastLookup = now;
          IOSurfaceRef latest = currentSurface();
          if (latest && latest != surface) {
            if (surface) CFRelease(surface);
            surface = latest;
            forceKey = true;
            seed = IOSurfaceGetSeed(surface) - 1;
          } else if (latest) {
            CFRelease(latest);
          }
        }
        if (surface && (IOSurfaceGetWidth(surface) != width || IOSurfaceGetHeight(surface) != height)) {
          width = IOSurfaceGetWidth(surface);
          height = IOSurfaceGetHeight(surface);
          if (encoder) {
            VTCompressionSessionInvalidate(encoder);
            CFRelease(encoder);
          }
          VTCompressionSessionCreate(
              NULL, (int32_t)width, (int32_t)height, kCMVideoCodecType_H264,
              (__bridge CFDictionaryRef)@{
                (id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @YES
              },
              NULL, NULL, encoded, NULL, &encoder);
          VTSessionSetProperty(encoder, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
          VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
          VTSessionSetProperty(encoder, kVTCompressionPropertyKey_AverageBitRate, (__bridge CFTypeRef) @6000000);
          VTSessionSetProperty(encoder, kVTCompressionPropertyKey_MaxKeyFrameInterval, (__bridge CFTypeRef) @240);
          forceKey = true;
        }
        if (surface && encoder && (IOSurfaceGetSeed(surface) != seed || keyRequested) && now - lastFrame > 16000000ull) {
          seed = IOSurfaceGetSeed(surface);
          lastFrame = now;
          CVPixelBufferRef buffer = NULL;
          CVPixelBufferCreateWithIOSurface(NULL, surface, NULL, &buffer);
          if (buffer) {
            NSDictionary *properties =
                (forceKey || keyRequested) ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame : @YES} : nil;
            forceKey = false;
            keyRequested = false;
            VTCompressionSessionEncodeFrame(encoder, buffer, CMTimeMake(index++, 60), kCMTimeInvalid,
                                            (__bridge CFDictionaryRef)properties, NULL, NULL);
            CVPixelBufferRelease(buffer);
          }
        }
        usleep(2000);
      }
    }
  }
}
