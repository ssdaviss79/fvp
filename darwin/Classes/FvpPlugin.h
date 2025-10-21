#if __has_include(<Flutter/Flutter.h>)
#import <Flutter/Flutter.h>
#else
#import <FlutterMacOS/FlutterMacOS.h>
#endif

@interface FvpPlugin : NSObject<FlutterPlugin>
- (id)getDisplayLayerForTexture:(int64_t)textureId;
- (id)getPipControllerForTexture:(int64_t)textureId;
- (void)sendLogToFlutter:(NSString*)message;
@end
