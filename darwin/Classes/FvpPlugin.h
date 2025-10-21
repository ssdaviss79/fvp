// FvpPlugin.h
#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

// Forward declarations
@protocol FlutterTextureRegistry;
@class FvpPipController;

// Main plugin interface
@interface FvpPlugin : NSObject<FlutterPlugin>
@property (nonatomic, strong, readonly) NSObject<FlutterTextureRegistry> *texRegistry;
@property (nonatomic, strong) FlutterMethodChannel *channel;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, FvpPipController*> *pipControllers;

// Designated initializer
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
@end

// PiP Controller interface
@interface FvpPipController : NSObject <AVPictureInPictureControllerDelegate>
@property (nonatomic, strong) AVPictureInPictureController *pipController;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *pipLayer;  // Updated: Sample buffer for FFmpeg
@property (nonatomic, assign) int64_t textureId;
@property (nonatomic, strong) FlutterMethodChannel *channel;
@end
