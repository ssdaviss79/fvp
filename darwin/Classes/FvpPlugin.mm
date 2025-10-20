#import "FvpPlugin.h"
#import <Flutter/Flutter.h>
#import <AVFoundation/AVFoundation.h>
#import <mutex>

using namespace std;

// Shared dictionary to track active Picture-in-Picture layers
static NSMutableDictionary<NSNumber *, CALayer *> *pipLayers;

#pragma mark - FvpPlugin Implementation

@implementation FvpPlugin

+ (void)registerPipLayer:(CALayer *)layer forTextureId:(int64_t)textureId {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pipLayers = [NSMutableDictionary dictionary];
    });
    @synchronized(pipLayers) {
        pipLayers[@(textureId)] = layer;
    }
}

+ (void)unregisterPipLayerForTextureId:(int64_t)textureId {
    @synchronized(pipLayers) {
        [pipLayers removeObjectForKey:@(textureId)];
    }
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel = [FlutterMethodChannel
        methodChannelWithName:@"fvp"
              binaryMessenger:[registrar messenger]];

    FvpPlugin* instance = [[FvpPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"getPlatformVersion" isEqualToString:call.method]) {
        result([@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]]);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

@end

#pragma mark - TexturePlayer Implementation

@interface TexturePlayer : NSObject
@property(nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property(nonatomic, assign) int64_t texId;
@end

@implementation TexturePlayer {
    std::mutex mtx_;
    NSObject<FlutterTextureRegistry>* texReg_;
}

- (instancetype)initWithTextureRegistry:(NSObject<FlutterTextureRegistry>*)texReg
                                 width:(int)width
                                height:(int)height
{
    self = [super init];
    if (self) {
        texReg_ = texReg;
        _displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
        _displayLayer.frame = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;

        // Register this PiP layer with the plugin
        [FvpPlugin registerPipLayer:_displayLayer forTextureId:self.texId];
    }
    return self;
}

- (void)dealloc {
    // Unregister PiP layer when player is destroyed
    [FvpPlugin unregisterPipLayerForTextureId:self.texId];
}

- (void)startRendering {
    __weak TexturePlayer *weakSelf = self;

    auto renderCallback = [this, weakSelf](void* opaque) {
        std::lock_guard<std::mutex> lock(mtx_);
        TexturePlayer *strongSelf = weakSelf;
        if (!strongSelf) return;

        int64_t tid = strongSelf.texId;
        __unsafe_unretained NSObject<FlutterTextureRegistry>* registry = texReg_;

        dispatch_async(dispatch_get_main_queue(), ^{
            [registry textureFrameAvailable:tid];
            [strongSelf bridgeFrameToPipLayer];
        });
    };

    // You can now attach this callback to the underlying video decoder/render loop.
}

- (void)bridgeFrameToPipLayer {
    // Called when a new frame is available.
    // Here you can update the PiP layer’s contents or synchronize with display timing.
    if (!_displayLayer) return;

    // Example placeholder:
    // NSLog(@"[PiP] Frame bridged to textureId: %lld", self.texId);
}

@end
