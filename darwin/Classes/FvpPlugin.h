#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#if TARGET_OS_IPHONE
#import <AVKit/AVKit.h>
#endif

#if TARGET_OS_IPHONE
@interface FvpPlugin : NSObject<FlutterPlugin, AVPictureInPictureControllerDelegate>
#else
@interface FvpPlugin : NSObject<FlutterPlugin>
#endif
- (void)syncFrameToPipForTextureId:(int64_t)textureId pixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end
