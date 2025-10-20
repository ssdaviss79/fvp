#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>

@interface FvpPlugin : NSObject<FlutterPlugin>

// Picture-in-Picture layer registration
+ (void)registerPipLayer:(CALayer *)layer forTextureId:(int64_t)textureId;
+ (void)unregisterPipLayerForTextureId:(int64_t)textureId;

@end
