#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

@interface FvpPlugin : NSObject<FlutterPlugin, AVPictureInPictureControllerDelegate>
- (void)syncFrameToPipForTextureId:(int64_t)textureId pixelBuffer:(CVPixelBufferRef)pixelBuffer;
@end
