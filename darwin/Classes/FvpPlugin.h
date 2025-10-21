#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif

@interface FvpPlugin : NSObject<FlutterPlugin>
- (AVPlayerLayer*)getDisplayLayerForTexture:(int64_t)textureId;
- (AVPictureInPictureController*)getPipControllerForTexture:(int64_t)textureId;
- (void)sendLogToFlutter:(NSString*)message;
@end
