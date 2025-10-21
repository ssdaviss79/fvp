// FvpPlugin.h
#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

// Forward declarations for Flutter and custom classes
@protocol FlutterTextureRegistry;
@class FvpPipController;

// Main plugin interface
@interface FvpPlugin : NSObject<FlutterPlugin>

// Properties used in implementation
@property (nonatomic, strong, readonly) NSObject<FlutterTextureRegistry> *texRegistry;
@property (nonatomic, strong) FlutterMethodChannel *channel;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, FvpPipController*> *pipControllers;

// Designated initializer
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;

// PiP methods (private; declared for internal use)
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
