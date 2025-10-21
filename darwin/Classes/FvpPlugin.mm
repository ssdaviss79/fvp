// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define USE_TEXCACHE 0

#import "FvpPlugin.h"
#include "mdk/RenderAPI.h"
#include "mdk/Player.h"
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <Metal/Metal.h>
#include <mutex>
#include <unordered_map>
#include <iostream>

using namespace mdk;
using namespace std;

@interface MetalTexture : NSObject<FlutterTexture>
@end

@implementation MetalTexture {
    @public
    id<MTLDevice> device;
    id<MTLCommandQueue> cmdQueue;
    id<MTLTexture> texture;
    CVPixelBufferRef pixbuf;
    id<MTLTexture> fltex;
    CVMetalTextureCacheRef texCache;
    mutex mtx; // ensure whole frame render pass commands are recorded before blitting
}

- (instancetype)initWithWidth:(int)width height:(int)height
{
    self = [super init];
    device = MTLCreateSystemDefaultDevice();
    cmdQueue = [device newCommandQueue];
    auto td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    texture = [device newTextureWithDescriptor:td];
    //assert(!texture.iosurface); // CVPixelBufferCreateWithIOSurface(fltex.iosurface)
    auto attr = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attr, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
    auto iosurface_props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attr, kCVPixelBufferIOSurfacePropertiesKey, iosurface_props); // optional?
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attr, &pixbuf);
    CFRelease(attr);
    texCache = {};
#if (USE_TEXCACHE + 0)
    CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &texCache);
    CVMetalTextureRef cvtex;
    CVMetalTextureCacheCreateTextureFromImage(nil, texCache, pixbuf, nil, MTLPixelFormatBGRA8Unorm, width, height, 0, &cvtex);
    fltex = CVMetalTextureGetTexture(cvtex);
    CFRelease(cvtex);
#else
    auto iosurface = CVPixelBufferGetIOSurface(pixbuf);
    td.usage = MTLTextureUsageShaderRead; // Unknown?
// macos: failed assertion `Texture Descriptor Validation IOSurface textures must use MTLStorageModeManaged or MTLStorageModeShared'
// ios: failed assertion `Texture Descriptor Validation IOSurface textures must use MTLStorageModeShared
    fltex = [device newTextureWithDescriptor:td iosurface:iosurface plane:0];
#endif
    return self;
}

- (void)dealloc {
    CVPixelBufferRelease(pixbuf);
    if (texCache)
        CFRelease(texCache);
}

- (CVPixelBufferRef _Nullable)copyPixelBuffer {
    //return CVPixelBufferRetain(pixbuf);
    scoped_lock lock(mtx);
    auto cmdbuf = [cmdQueue commandBuffer];
    auto blit = [cmdbuf blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(texture.width, texture.height, texture.depth)
        toTexture:fltex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)]; // macos 10.15
    [blit endEncoding];
    [cmdbuf commit];
    return CVPixelBufferRetain(pixbuf);
}
@end


class TexturePlayer final: public Player
{
public:
    TexturePlayer(int64_t handle, int width, int height, NSObject<FlutterTextureRegistry>* texReg, FvpPlugin* plugin)
        : Player(reinterpret_cast<mdkPlayerAPI*>(handle))
    {
        mtex_ = [[MetalTexture alloc] initWithWidth:width height:height];
        texId_ = [texReg registerTexture:mtex_];
        plugin_ = plugin;
        MetalRenderAPI ra{};
        ra.device = (__bridge void*)mtex_->device;
        ra.cmdQueue = (__bridge void*)mtex_->cmdQueue;
// TODO: texture pool to avoid blitting
        ra.texture = (__bridge void*)mtex_->texture;
        setRenderAPI(&ra);
        setVideoSurfaceSize(width, height);

        setRenderCallback([this, texReg](void* opaque){
            scoped_lock lock(mtex_->mtx);
            renderVideo();
            [texReg textureFrameAvailable:texId_];
            
            // Sync frame to PiP if enabled
            syncFrameToPip();
        });
    }

    ~TexturePlayer() override {
        setRenderCallback(nullptr);
        setVideoSurfaceSize(-1, -1);
    }

    int64_t textureId() const { return texId_;}
    
    void syncFrameToPip() {
        // For now, we'll use a simple approach without frame synchronization
        // The PiP will show a placeholder or the last frame
        // This is a limitation of using AVPlayerLayer with mdk's Metal rendering
        if (!plugin_) return;
        
        // Check if PiP is active for this texture
        AVPictureInPictureController *pipController = [plugin_ getPipControllerForTexture:texId_];
        if (!pipController || !pipController.isPictureInPictureActive) return;
        
        // Log that PiP is active (frame sync is not implemented for AVPlayerLayer approach)
        static int frameCount = 0;
        if (frameCount % 60 == 0) { // Log every 60 frames (once per second at 60fps)
            [plugin_ sendLogToFlutter:@"Native: PiP active (frame sync not implemented)"];
        }
        frameCount++;
    }
    
    CMSampleBufferRef createSampleBufferFromPixelBuffer(CVPixelBufferRef pixelBuffer) {
        CMVideoFormatDescriptionRef formatDesc;
        OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDesc);
        if (status != noErr) {
            return NULL;
        }
        
        CMTime timestamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000); // Current time
        CMSampleTimingInfo timingInfo = { 
            .duration = kCMTimeInvalid, 
            .presentationTimeStamp = timestamp, 
            .decodeTimeStamp = kCMTimeInvalid 
        };
        
        CMSampleBufferRef sampleBuffer;
        status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, formatDesc, &timingInfo, &sampleBuffer);
        
        CFRelease(formatDesc);
        return sampleBuffer;
    }
    
private:
    int64_t texId_ = 0;
    MetalTexture* mtex_ = nil;
    __weak FvpPlugin* plugin_;
};


@interface FvpPlugin () <AVPictureInPictureControllerDelegate> {
    unordered_map<int64_t, shared_ptr<TexturePlayer>> players;
}
@property(readonly, strong, nonatomic) NSObject<FlutterTextureRegistry>* texRegistry;
@property(strong, nonatomic) NSMutableDictionary<NSNumber*, AVPictureInPictureController*>* pipControllers;
@property(strong, nonatomic) NSMutableDictionary<NSNumber*, AVPlayerLayer*>* pipLayers;
@property(strong, nonatomic) NSMutableDictionary<NSNumber*, UIView*>* pipDummyViews;
@end

@implementation FvpPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
#if TARGET_OS_OSX
    auto messenger = registrar.messenger;
#else
    auto messenger = [registrar messenger];
  // Allow audio playback when the Ring/Silent switch is set to silent
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
#endif
    FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"fvp" binaryMessenger:messenger];
    FvpPlugin* instance = [[FvpPlugin alloc] initWithRegistrar:registrar];
#if TARGET_OS_OSX
#else
  [registrar addApplicationDelegate:instance];
#endif
    [registrar publish:instance];
    [registrar addMethodCallDelegate:instance channel:channel];
    SetGlobalOption("MDK_KEY", "C03BFF5306AB39058A767105F82697F42A00FE970FB0E641D306DEFF3F220547E5E5377A3C504DC30D547890E71059BC023A4DD91A95474D1F33CA4C26C81B0FC73B00ACF954C6FA75898EFA07D9680B6A00FDF179C0A15381101D01124498AF55B069BD4B0156D5CF5A56DEDE782E5F3930AD47C8F40BFBA379231142E31B0F");
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    self = [super init];
#if TARGET_OS_OSX
    _texRegistry = registrar.textures;
#else
    _texRegistry = [registrar textures];
#endif
    // Initialize PiP state management dictionaries
    _pipControllers = [NSMutableDictionary dictionary];
    _pipLayers = [NSMutableDictionary dictionary];
    _pipDummyViews = [NSMutableDictionary dictionary];
    return self;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"CreateRT"]) {
        const auto handle = ((NSNumber*)call.arguments[@"player"]).longLongValue;
        const auto width = ((NSNumber*)call.arguments[@"width"]).intValue;
        const auto height = ((NSNumber*)call.arguments[@"height"]).intValue;
        auto player = make_shared<TexturePlayer>(handle, width, height, _texRegistry, self);
        players[player->textureId()] = player;
        result(@(player->textureId()));
    } else if ([call.method isEqualToString:@"ReleaseRT"]) {
        const auto texId = ((NSNumber*)call.arguments[@"texture"]).longLongValue;
        [_texRegistry unregisterTexture:texId];
        players.erase(texId);
        // Clean up PiP resources
        [self cleanupPipForTextureId:texId];
        result(nil);
    } else if ([call.method isEqualToString:@"MixWithOthers"]) {
        [[maybe_unused]] const auto value = ((NSNumber*)call.arguments[@"value"]).boolValue;
#if TARGET_OS_OSX
#else
        if (value) {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
        } else {
            [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        }
#endif
        result(nil);
    } else if ([call.method isEqualToString:@"enablePipForTexture"]) {
        NSLog(@"🔧 PiP: enablePipForTexture called");
        
        // Check if PiP is supported
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            NSLog(@"❌ PiP: Picture-in-Picture not supported on this device");
            result([FlutterError errorWithCode:@"NOT_SUPPORTED" message:@"PiP not supported" details:nil]);
            return;
        }
        
        NSLog(@"✅ PiP: Picture-in-Picture is supported");
        
        // Create a simple approach: use a dummy video file for PiP
        // This is a workaround since we can't easily sync mdk frames to AVPlayerLayer
        NSURL *dummyVideoURL = [NSURL URLWithString:@"about:blank"];
        NSLog(@"🔧 PiP: Creating dummy video URL: %@", dummyVideoURL);
        
        AVPlayerItem *dummyItem = [AVPlayerItem playerItemWithURL:dummyVideoURL];
        NSLog(@"🔧 PiP: Created dummy player item: %@", dummyItem);
        
        AVPlayer *pipPlayer = [AVPlayer playerWithPlayerItem:dummyItem];
        NSLog(@"🔧 PiP: Created pip player: %@", pipPlayer);
        
        AVPlayerLayer *pipLayer = [AVPlayerLayer playerLayerWithPlayer:pipPlayer];
        pipLayer.frame = CGRectMake(0, 0, 640, 360); // Default size, will be updated
        pipLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        pipLayer.hidden = YES;
        NSLog(@"🔧 PiP: Created player layer with frame: %@", NSStringFromCGRect(pipLayer.frame));
        
        // Create dummy view to hold the player layer
        UIView *dummyView = [[UIView alloc] initWithFrame:pipLayer.frame];
        [dummyView.layer addSublayer:pipLayer];
        dummyView.hidden = YES;
        NSLog(@"🔧 PiP: Created dummy view with frame: %@", NSStringFromCGRect(dummyView.frame));
        
        // Add to view hierarchy
        UIViewController *rootVC = [UIApplication sharedApplication].windows.firstObject.rootViewController;
        if (rootVC) {
            [rootVC.view addSubview:dummyView];
            NSLog(@"🔧 PiP: Added dummy view to root view controller");
        } else {
            NSLog(@"❌ PiP: No root view controller found!");
        }
        
        // Store references using a simple key (0 for global PiP)
        [_pipLayers setObject:pipLayer forKey:@(0)];
        [_pipDummyViews setObject:dummyView forKey:@(0)];
        
        NSLog(@"✅ PiP: Layer created and stored for global PiP");
        result(@YES);
    } else if ([call.method isEqualToString:@"enterPipMode"]) {
        NSLog(@"🔧 PiP: enterPipMode called");
        
        // Use global PiP layer (key 0)
        AVPlayerLayer *pipLayer = [_pipLayers objectForKey:@(0)];
        if (!pipLayer) {
            NSLog(@"❌ PiP: No layer found for global PiP");
            result([FlutterError errorWithCode:@"NO_LAYER" message:@"PiP not enabled" details:nil]);
            return;
        }
        
        NSLog(@"✅ PiP: Found layer for global PiP: %@", pipLayer);
        
        // Check if PiP is already active
        AVPictureInPictureController *existingController = [_pipControllers objectForKey:@(0)];
        if (existingController && existingController.isPictureInPictureActive) {
            NSLog(@"⚠️ PiP: Already active, stopping first");
            [existingController stopPictureInPicture];
        }
        
        // Create PiP controller with player layer
        NSLog(@"🔧 PiP: Creating AVPictureInPictureController...");
        AVPictureInPictureController *pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:pipLayer];
        
        if (!pipController) {
            NSLog(@"❌ PiP: Failed to create AVPictureInPictureController");
            result(@NO);
            return;
        }
        
        NSLog(@"✅ PiP: Created AVPictureInPictureController: %@", pipController);
        
        pipController.delegate = self;
        if (@available(iOS 14.2, *)) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
            NSLog(@"🔧 PiP: Set canStartPictureInPictureAutomaticallyFromInline = YES");
        }
        
        [_pipControllers setObject:pipController forKey:@(0)];
        
        NSLog(@"🔧 PiP: Starting Picture-in-Picture...");
        [pipController startPictureInPicture];
        
        NSLog(@"✅ PiP: startPictureInPicture called for global PiP");
        result(@YES);
    } else if ([call.method isEqualToString:@"exitPipMode"]) {
        NSLog(@"🔧 PiP: exitPipMode called");
        
        // Use global PiP controller (key 0)
        AVPictureInPictureController *pipController = [_pipControllers objectForKey:@(0)];
        if (pipController) {
            NSLog(@"🔧 PiP: Found controller, stopping Picture-in-Picture...");
            NSLog(@"🔧 PiP: Is PiP active before stop: %@", pipController.isPictureInPictureActive ? @"YES" : @"NO");
            [pipController stopPictureInPicture];
            NSLog(@"✅ PiP: stopPictureInPicture called for global PiP");
        } else {
            NSLog(@"⚠️ PiP: No controller found for global PiP");
        }
        result(@YES);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

// AVPictureInPictureControllerDelegate methods
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"🔄 PiP: Will start Picture-in-Picture");
    NSLog(@"🔧 PiP: Controller: %@", pictureInPictureController);
    NSLog(@"🔧 PiP: Is PiP supported: %@", [AVPictureInPictureController isPictureInPictureSupported] ? @"YES" : @"NO");
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"✅ PiP: Did start Picture-in-Picture");
    NSLog(@"🔧 PiP: Controller: %@", pictureInPictureController);
    NSLog(@"🔧 PiP: Is PiP active: %@", pictureInPictureController.isPictureInPictureActive ? @"YES" : @"NO");
    [self sendLogToFlutter:@"Native: ✅ PiP did start"];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"🔄 PiP: Will stop Picture-in-Picture");
    NSLog(@"🔧 PiP: Controller: %@", pictureInPictureController);
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"✅ PiP: Did stop Picture-in-Picture");
    NSLog(@"🔧 PiP: Controller: %@", pictureInPictureController);
    [self sendLogToFlutter:@"Native: ✅ PiP did stop"];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"❌ PiP: Failed to start Picture-in-Picture");
    NSLog(@"🔧 PiP: Controller: %@", pictureInPictureController);
    NSLog(@"🔧 PiP: Error: %@", error);
    NSLog(@"🔧 PiP: Error code: %ld", (long)error.code);
    NSLog(@"🔧 PiP: Error domain: %@", error.domain);
    NSLog(@"🔧 PiP: Error userInfo: %@", error.userInfo);
    
    [self sendLogToFlutter:[NSString stringWithFormat:@"Native: ❌ PiP failed: %@", error.localizedDescription]];
    
    if (error.code == -1001) {
        NSLog(@"🔧 PiP: Error -1001: PiP already active");
        [self sendLogToFlutter:@"Native: Error - PiP already active"];
    } else if (error.code == -1002) {
        NSLog(@"🔧 PiP: Error -1002: PiP disabled");
        [self sendLogToFlutter:@"Native: Error - PiP disabled"];
    } else {
        NSLog(@"🔧 PiP: Unknown error code: %ld", (long)error.code);
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    NSLog(@"🔄 Restore UI for PiP stop");
    [self sendLogToFlutter:@"Native: Restore UI for PiP stop"];
    
    // Reactivate audio session
    NSError *error;
    if (![[AVAudioSession sharedInstance] setActive:YES withOptions:0 error:&error]) {
        [self sendLogToFlutter:[NSString stringWithFormat:@"Native: Failed to reactivate audio: %@", error.localizedDescription]];
    }
    
    completionHandler(YES);
}

// Helper method to get player layer for global PiP
- (AVPlayerLayer*)getDisplayLayerForTexture:(int64_t)textureId {
    return [_pipLayers objectForKey:@(0)];  // Always use global key 0
}

// Helper method to get PiP controller for global PiP
- (AVPictureInPictureController*)getPipControllerForTexture:(int64_t)textureId {
    return [_pipControllers objectForKey:@(0)];  // Always use global key 0
}

// Helper method to send logs to Flutter
- (void)sendLogToFlutter:(NSString*)message {
    NSLog(@"%@", message);
    // Could add Flutter channel call here if needed
}

// Helper method to cleanup PiP resources
- (void)cleanupPipForTextureId:(int64_t)textureId {
    // Clean up global PiP resources (key 0)
    NSNumber *globalKey = @(0);
    
    // Stop PiP controller if active
    AVPictureInPictureController *pipController = [_pipControllers objectForKey:globalKey];
    if (pipController && pipController.isPictureInPictureActive) {
        [pipController stopPictureInPicture];
    }
    [_pipControllers removeObjectForKey:globalKey];
    
    // Clean up player layer
    [_pipLayers removeObjectForKey:globalKey];
    
    // Clean up dummy view
    UIView *dummyView = [_pipDummyViews objectForKey:globalKey];
    if (dummyView) {
        [dummyView removeFromSuperview];
        [_pipDummyViews removeObjectForKey:globalKey];
    }
    
    NSLog(@"🧹 Cleaned up global PiP resources");
}

// ios only, optional. called first in dealloc(texture registry is still alive). plugin instance must be registered via publish
- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  players.clear();
  // Clean up all PiP resources
  for (auto& pair : players) {
      [self cleanupPipForTextureId:pair.first];
  }
}

#if TARGET_OS_OSX
#else
- (void)applicationWillTerminate:(UIApplication *)application {
  players.clear();
  // Clean up all PiP resources
  for (auto& pair : players) {
      [self cleanupPipForTextureId:pair.first];
  }
}
#endif
@end
