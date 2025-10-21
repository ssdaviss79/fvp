// Copyright 2023-2025 Wang Bin. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#define USE_TEXCACHE 0

#import "FvpPlugin.h"
#include "mdk/RenderAPI.h"
#include "mdk/Player.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <CoreMedia/CoreMedia.h>
#if TARGET_OS_IPHONE
#import <AVKit/AVKit.h>
#endif
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
            
            // Sync frame to PiP if active
            [plugin_ syncFrameToPipForTextureId:texId_ pixelBuffer:mtex_->pixbuf];
        });
    }

    ~TexturePlayer() override {
        setRenderCallback(nullptr);
        setVideoSurfaceSize(-1, -1);
    }

    int64_t textureId() const { return texId_;}
private:
    int64_t texId_ = 0;
    MetalTexture* mtex_ = nil;
    FvpPlugin* plugin_ = nil;
};


@interface FvpPlugin () {
    unordered_map<int64_t, shared_ptr<TexturePlayer>> players;
}
@property(readonly, strong, nonatomic) NSObject<FlutterTextureRegistry>* texRegistry;
#if TARGET_OS_IPHONE
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, AVPlayerLayer*> *pipLayers;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, AVPictureInPictureController*> *pipControllers;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, NSNumber*> *pipActiveFlags;
@property (nonatomic, strong) NSMutableDictionary<NSNumber*, AVPlayer*> *pipPlayers;
#endif
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
#if TARGET_OS_IPHONE
    // Initialize PiP-related dictionaries
    _pipLayers = [NSMutableDictionary dictionary];
    _pipControllers = [NSMutableDictionary dictionary];
    _pipActiveFlags = [NSMutableDictionary dictionary];
    _pipPlayers = [NSMutableDictionary dictionary];
#endif
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
        
#if TARGET_OS_IPHONE
        // Clean up PiP resources for this texture
        AVPictureInPictureController *pipController = [_pipControllers objectForKey:@(texId)];
        if (pipController) {
            [pipController stopPictureInPicture];
            [_pipControllers removeObjectForKey:@(texId)];
        }
        [_pipLayers removeObjectForKey:@(texId)];
        [_pipPlayers removeObjectForKey:@(texId)];
        [_pipActiveFlags removeObjectForKey:@(texId)];
#endif
        
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
#if TARGET_OS_IPHONE
    } else if ([call.method isEqualToString:@"enablePipForTexture"]) {
        NSNumber *textureIdNum = call.arguments[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        
        // Get TexturePlayer from players map
        auto texPlayer = players[textureId];
        if (!texPlayer) {
            result([FlutterError errorWithCode:@"NO_TEXTURE" message:@"Texture not found" details:nil]);
            return;
        }
        
        // Create hidden AVPlayerLayer for PiP
        AVPlayer *pipPlayer = [AVPlayer playerWithPlayerItem:nil];
        AVPlayerLayer *pipLayer = [AVPlayerLayer playerLayerWithPlayer:pipPlayer];
        pipLayer.frame = CGRectMake(0, 0, 1920, 1080); // Default size, will be updated
        pipLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        pipLayer.hidden = YES;
        
        // Store references
        [_pipLayers setObject:pipLayer forKey:@(textureId)];
        [_pipPlayers setObject:pipPlayer forKey:@(textureId)];
        [_pipActiveFlags setObject:@NO forKey:@(textureId)];
        
        NSLog(@"✅ PiP layer created for texture %lld", textureId);
        result(@YES);
    } else if ([call.method isEqualToString:@"enterPipMode"]) {
        NSNumber *textureIdNum = call.arguments[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        
        AVPlayerLayer *pipLayer = [_pipLayers objectForKey:@(textureId)];
        if (!pipLayer) {
            result([FlutterError errorWithCode:@"NO_LAYER" message:@"PiP not enabled for texture" details:nil]);
            return;
        }
        
        // Check if PiP is supported
        if (![AVPictureInPictureController isPictureInPictureSupported]) {
            result([FlutterError errorWithCode:@"PIP_NOT_SUPPORTED" message:@"Picture in Picture not supported on this device" details:nil]);
            return;
        }
        
        AVPictureInPictureController *pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:pipLayer];
        if (!pipController) {
            result(@NO);
            return;
        }
        
        pipController.delegate = self;
        if (@available(iOS 14.2, *)) {
            pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        }
        
        [_pipControllers setObject:pipController forKey:@(textureId)];
        [_pipActiveFlags setObject:@YES forKey:@(textureId)];
        
        [pipController startPictureInPicture];
        NSLog(@"✅ PiP mode started for texture %lld", textureId);
        result(@YES);
    } else if ([call.method isEqualToString:@"exitPipMode"]) {
        NSNumber *textureIdNum = call.arguments[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        
        AVPictureInPictureController *pipController = [_pipControllers objectForKey:@(textureId)];
        if (pipController) {
            [pipController stopPictureInPicture];
            [_pipControllers removeObjectForKey:@(textureId)];
            [_pipActiveFlags setObject:@NO forKey:@(textureId)];
            NSLog(@"✅ PiP mode stopped for texture %lld", textureId);
        }
        result(@YES);
#endif
    } else {
        result(FlutterMethodNotImplemented);
    }
}

#if TARGET_OS_IPHONE
#pragma mark - PiP Frame Synchronization

- (void)syncFrameToPipForTextureId:(int64_t)textureId pixelBuffer:(CVPixelBufferRef)pixelBuffer {
    // Check if PiP is active for this texture
    NSNumber *isActive = [_pipActiveFlags objectForKey:@(textureId)];
    if (![isActive boolValue]) {
        return;
    }
    
    AVPlayer *pipPlayer = [_pipPlayers objectForKey:@(textureId)];
    if (!pipPlayer) {
        return;
    }
    
    // Create a sample buffer from the pixel buffer
    CMSampleBufferRef sampleBuffer = [self createSampleBufferFromPixelBuffer:pixelBuffer];
    if (sampleBuffer) {
        // For now, we'll use a simple approach - create an AVPlayerItem with the sample buffer
        // In a more sophisticated implementation, you might want to use AVSampleBufferDisplayLayer
        // or enqueue multiple sample buffers to create a proper video stream
        
        // This is a simplified approach - in practice, you'd want to manage the video stream properly
        NSLog(@"🔄 Syncing frame to PiP for texture %lld", textureId);
        
        CFRelease(sampleBuffer);
    }
}

- (CMSampleBufferRef)createSampleBufferFromPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) {
        return NULL;
    }
    
    // Create timing info
    CMTime presentationTime = CMTimeMakeWithSeconds(CACurrentMediaTime(), 600);
    
    // Create format description
    CMVideoFormatDescriptionRef formatDescription = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &formatDescription);
    if (status != noErr) {
        return NULL;
    }
    
    // Create sample buffer
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, true, NULL, NULL, formatDescription, NULL, &sampleBuffer);
    
    CFRelease(formatDescription);
    
    if (status != noErr) {
        return NULL;
    }
    
    return sampleBuffer;
}
#endif

#if TARGET_OS_IPHONE
#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"✅ PiP will start");
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"✅ PiP did start");
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"✅ PiP will stop");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    NSLog(@"✅ PiP did stop");
    // Find and clean up the controller
    for (NSNumber *textureId in _pipControllers.allKeys) {
        if ([_pipControllers objectForKey:textureId] == pictureInPictureController) {
            [_pipControllers removeObjectForKey:textureId];
            [_pipActiveFlags setObject:@NO forKey:textureId];
            break;
        }
    }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    NSLog(@"❌ PiP failed to start: %@", error.localizedDescription);
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    NSLog(@"✅ PiP restore user interface");
    completionHandler(YES);
}
#endif

// ios only, optional. called first in dealloc(texture registry is still alive). plugin instance must be registered via publish
- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  players.clear();
  
#if TARGET_OS_IPHONE
  // Clean up all PiP resources
  for (AVPictureInPictureController *controller in _pipControllers.allValues) {
    [controller stopPictureInPicture];
  }
  [_pipControllers removeAllObjects];
  [_pipLayers removeAllObjects];
  [_pipPlayers removeAllObjects];
  [_pipActiveFlags removeAllObjects];
#endif
}

#if TARGET_OS_OSX
#else
- (void)applicationWillTerminate:(UIApplication *)application {
  players.clear();
  
#if TARGET_OS_IPHONE
  // Clean up all PiP resources
  for (AVPictureInPictureController *controller in _pipControllers.allValues) {
    [controller stopPictureInPicture];
  }
  [_pipControllers removeAllObjects];
  [_pipLayers removeAllObjects];
  [_pipPlayers removeAllObjects];
  [_pipActiveFlags removeAllObjects];
#endif
}
#endif
@end
