// FvpPlugin.h
#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

// Forward declarations
@protocol FlutterTextureRegistry;
@class FvpPipController;

// Main plugin interface
@interface FvpPlugin : NSObject<FlutterPlugin>

// Flutter texture registry for rendering
@property (nonatomic, strong, readonly) NSObject<FlutterTextureRegistry> *texRegistry;

// Method channel for communication with Dart
@property (nonatomic, strong) FlutterMethodChannel *channel;

// Map of textureId -> PiP controllers
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, FvpPipController*> *pipControllers;

// Designated initializer
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;

@end

// PiP Controller interface (public)
@interface FvpPipController : NSObject <AVPictureInPictureControllerDelegate>

// Public properties
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, assign) int64_t textureId;
@property (nonatomic, strong) FlutterMethodChannel *channel;

@end
