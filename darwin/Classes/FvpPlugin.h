// FvpPlugin.h
#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

// Forward declaration
@class FvpPipController;

@interface FvpPlugin : NSObject<FlutterPlugin>
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
- (BOOL)enablePipForTexture:(int64_t)texId;
- (BOOL)enterPipModeForTexture:(int64_t)texId width:(int)width height:(int)height;
@end

// PiP Controller interface
@interface FvpPipController : NSObject <AVPictureInPictureControllerDelegate>
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) AVPlayerLayer *pipLayer;
@property (nonatomic, assign) int64_t textureId;
@property (nonatomic, strong) FlutterMethodChannel *channel;
@end
