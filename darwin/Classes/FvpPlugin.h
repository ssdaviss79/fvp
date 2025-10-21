// FvpPlugin.h
#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

@class FvpPipController;

@interface FvpPlugin : NSObject<FlutterPlugin>
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
- (BOOL)enablePipForTexture:(int64_t)texId;  // DECLARED METHODS
- (BOOL)enterPipModeForTexture:(int64_t)texId width:(int)width height:(int)height;
@end

// PiP Controller
@interface FvpPipController : NSObject
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *pipLayer;
@property (nonatomic, assign) int64_t textureId;
@end
