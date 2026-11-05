#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <malloc/malloc.h>
#import <mach/mach_time.h>
#import <ImageIO/ImageIO.h>
#import <CoreImage/CoreImage.h>
typedef void*(*MF)(CGPoint*,CGPoint*,uint32_t,uint32_t,uint32_t,double,double,double,double);typedef void*(*SF)(void);
static long bytes=0,frames=0,keyf=0;static double enc=0;
static void out(void*r,void*f,OSStatus st,VTEncodeInfoFlags fl,CMSampleBufferRef b){if(st||!b)return;bytes+=CMSampleBufferGetTotalSampleSize(b);frames++;enc+=[(NSDate*)CFBridgingRelease(f) timeIntervalSinceNow]*-1000;}
int main(int ac,char**av){setvbuf(stdout,NULL,_IONBF,0);@autoreleasepool{
 dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",RTLD_NOW);
 void*h=dlopen("/Applications/Xcode.app/Contents/SharedFrameworks/SimulatorKit.framework/Versions/A/SimulatorKit",RTLD_NOW);
 MF mf=dlsym(h,"IndigoHIDMessageForMouseNSEvent");
 id ctx=((id(*)(id,SEL,id,id*))objc_msgSend)(objc_getClass("SimServiceContext"),NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"),@"/Applications/Xcode.app/Contents/Developer",nil);
 id set=((id(*)(id,SEL,id*))objc_msgSend)(ctx,NSSelectorFromString(@"defaultDeviceSetWithError:"),nil);
 id dev=nil;for(id d in [set valueForKey:@"devices"]) if([[[d valueForKey:@"UDID"] UUIDString] isEqual:@(av[1])]) dev=d;
 IOSurfaceRef s=NULL;id io=[dev valueForKey:@"io"];
 for(id p in [io valueForKey:@"ioPorts"]){ id d=[p performSelector:@selector(descriptor)]; if([d respondsToSelector:@selector(framebufferSurface)]){id x=[d performSelector:@selector(framebufferSurface)]; if(x){IOSurfaceRef c=(__bridge IOSurfaceRef)x; if(!s||IOSurfaceGetWidth(c)>IOSurfaceGetWidth(s)) {s=c;CFRetain(s);}}}}
 size_t W=IOSurfaceGetWidth(s),H=IOSurfaceGetHeight(s);printf("surface %zux%zu fmt %x\n",W,H,IOSurfaceGetPixelFormat(s));
 NSError*e=nil;id hid=((id(*)(id,SEL,id,NSError**))objc_msgSend)([objc_getClass("_TtC12SimulatorKit24SimDeviceLegacyHIDClient") alloc],NSSelectorFromString(@"initWithDevice:error:"),dev,&e);printf("hid %p %s\n",hid,e?e.description.UTF8String:"");
 CGSize sz=strcmp(av[2],"px")==0?CGSizeMake(W,H):CGSizeMake(1,1);
 __auto_type raw=^(void*m){((void(*)(id,SEL,void*,BOOL,id,id))objc_msgSend)(hid,NSSelectorFromString(@"sendWithMessage:freeWhenDone:completionQueue:completion:"),m,YES,dispatch_get_global_queue(0,0),^(NSError*er){if(er)printf("send err %s\n",er.description.UTF8String);});};
 raw(((SF)dlsym(h,"IndigoHIDMessageToCreatePointerService"))());raw(((SF)dlsym(h,"IndigoHIDMessageToCreateMouseService"))());usleep(200000);
 void*io_=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW);
 typedef void*(*PF)(void*,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,bool,bool,uint32_t);
 typedef void*(*FF)(void*,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,bool,bool,uint32_t);
 PF pf=dlsym(io_,"IOHIDEventCreateDigitizerEvent");FF ff=dlsym(io_,"IOHIDEventCreateDigitizerFingerEvent");void(*ap)(void*,void*,uint32_t)=dlsym(io_,"IOHIDEventAppendEvent");void*(*wr)(void*)=dlsym(h,"IndigoHIDMessageForTrackpadEventFromHIDEventRef");
 __auto_type snd=^(double x,double y,uint32_t t){bool on=t!=2;uint32_t mk=on?7:6;uint64_t now=mach_absolute_time();void*P=pf(NULL,now,2,0,7,mk,0,x,y,0,0,0,on,on,0);void*Fi=ff(NULL,now,0,7,mk,x,y,0,0,0,on,on,0);ap(P,Fi,0);void*m=wr(P);if(!m){printf("NULL\n");return;}*(uint32_t*)((char*)m+0x6c)=0x32;if(malloc_size(m)>=0x110)*(uint32_t*)((char*)m+0x10c)=0x32;raw(m);CFRelease(Fi);CFRelease(P);};
 if(!strcmp(av[3],"tap")){snd(atof(av[4]),atof(av[5]),1);usleep(60000);snd(atof(av[4]),atof(av[5]),2);usleep(500000);return 0;}
 if(!strcmp(av[3],"shot")){CIImage*im=[CIImage imageWithIOSurface:s];CIContext*cx=[CIContext context];[cx writePNGRepresentationOfImage:im toURL:[NSURL fileURLWithPath:@(av[4])] format:kCIFormatBGRA8 colorSpace:CGColorSpaceCreateDeviceRGB() options:@{} error:nil];return 0;}
 VTCompressionSessionRef vt;size_t W2=W/2&~1,H2=H/2&~1;
 OSStatus st=VTCompressionSessionCreate(NULL,W,H,kCMVideoCodecType_H264,(__bridge CFDictionaryRef)@{(id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:@YES},NULL,NULL,out,NULL,&vt);printf("vt %d\n",st);
 VTSessionSetProperty(vt,kVTCompressionPropertyKey_RealTime,kCFBooleanTrue);VTSessionSetProperty(vt,kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse);VTSessionSetProperty(vt,kVTCompressionPropertyKey_AverageBitRate,(__bridge CFTypeRef)@4000000);

 uint32_t last=IOSurfaceGetSeed(s);int ch=0;NSDate*t=[NSDate date];int64_t c=0;
 int step=0;double y=.75;int dirn=-1;NSDate*nx=[NSDate date];
 while([t timeIntervalSinceNow]>-8){ if([nx timeIntervalSinceNow]<0){ if(step==0)snd(.5,y,1); else if(step<30){y+=dirn*.015;snd(.5,y,1);} else if(step==30){snd(.5,y,2);} step++; if(step>45){step=0;dirn=-dirn;y=dirn<0?.75:.3;} nx=[NSDate dateWithTimeIntervalSinceNow:.01]; }uint32_t x=IOSurfaceGetSeed(s);if(x!=last){last=x;ch++;CVPixelBufferRef pb;CVPixelBufferCreateWithIOSurface(NULL,s,NULL,&pb);if(pb){VTCompressionSessionEncodeFrame(vt,pb,CMTimeMake(c++,60),kCMTimeInvalid,NULL,(void*)CFBridgingRetain([NSDate date]),NULL);CVPixelBufferRelease(pb);}}usleep(1000);}
 VTCompressionSessionCompleteFrames(vt,kCMTimeInvalid);
 printf("frames seen %d (%.1f fps), encoded %ld, %.2f Mbit/s, encode avg %.1f ms\n",ch,ch/8.,frames,bytes*8/8./1e6,frames?enc/frames:0);
}return 0;}
