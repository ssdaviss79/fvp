#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

@interface FvpPlugin : NSObject<FlutterPlugin, AVPictureInPictureControllerDelegate>
- (AVSampleBufferDisplayLayer*)getDisplayLayerForTexture:(int64_t)textureId;
- (AVPictureInPictureController*)getPipControllerForTexture:(int64_t)textureId;
- (void)sendLogToFlutter:(NSString*)message;
- (void)cleanupPipForTextureId:(int64_t)textureId;
@end
