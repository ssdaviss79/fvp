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
#import <AVKit/AVKit.h>  // For PiP
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
    std::mutex mtx; // ensure whole frame render pass commands are recorded before blitting
}
- (instancetype)initWithWidth:(int)width height:(int)height
{
    self = [super init];
    if (self) {
        device = MTLCreateSystemDefaultDevice();
        cmdQueue = [device newCommandQueue];
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:width
                                                              height:height
                                                           mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget;
        texture = [device newTextureWithDescriptor:td];

        auto attr = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                              &kCFTypeDictionaryKeyCallBacks,
                                              &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attr, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
        auto iosurface_props =
            CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                      &kCFTypeDictionaryKeyCallBacks,
                                      &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(attr, kCVPixelBufferIOSurfacePropertiesKey, iosurface_props);
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attr, &pixbuf);
        CFRelease(attr);
        texCache = nullptr;
#if (USE_TEXCACHE + 0)
        CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &texCache);
        CVMetalTextureRef cvtex;
        CVMetalTextureCacheCreateTextureFromImage(nil, texCache, pixbuf, nil,
                                                  MTLPixelFormatBGRA8Unorm,
                                                  width, height, 0, &cvtex);
        fltex = CVMetalTextureGetTexture(cvtex);
        CFRelease(cvtex);
#else
        auto iosurface = CVPixelBufferGetIOSurface(pixbuf);
        td.usage = MTLTextureUsageShaderRead;
        fltex = [device newTextureWithDescriptor:td iosurface:iosurface plane:0];
#endif
    }
    return self;
}
- (void)dealloc {
    if (pixbuf) {
        CVPixelBufferRelease(pixbuf);
    }
    if (texCache) {
        CFRelease(texCache);
    }
}
- (CVPixelBufferRef _Nullable)copyPixelBuffer {
    std::lock_guard<std::mutex> lock(mtx);
    id<MTLCommandBuffer> cmdbuf = [cmdQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmdbuf blitCommandEncoder];
    [blit copyFromTexture:texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(texture.width, texture.height, texture.depth)
               toTexture:fltex
        destinationSlice:0
        destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    [cmdbuf commit];
    return CVPixelBufferRetain(pixbuf);
}
@end

// PiP Bridge: AVSampleBufferDisplayLayer for FFmpeg frames (SIMPLIFIED)
@interface PipDisplayLayer : NSObject
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, assign) int64_t textureId;
@end
@implementation PipDisplayLayer
- (instancetype)initWithTextureId:(int64_t)textureId width:(int)width height:(int)height {
    self = [super init];
    if (self) {
        _textureId = textureId;
        _displayLayer = [AVSampleBufferDisplayLayer layer];
        _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _displayLayer.hidden = YES;
        _displayLayer.frame = CGRectMake(0, 0, (CGFloat)width, (CGFloat)height);
        NSLog(@"Created PiP layer for texture %lld", textureId);
    }
    return self;
}
- (void)dealloc {
    if (_displayLayer.superlayer) {
        [_displayLayer removeFromSuperlayer];
    }
}
@end

class TexturePlayer final : public Player
{
public:
    TexturePlayer(int64_t handle, int width, int height,
                  NSObject<FlutterTextureRegistry>* texReg)
        : Player(reinterpret_cast<mdkPlayerAPI*>(handle))
    {
        mtex_ = [[MetalTexture alloc] initWithWidth:width height:height];
        texId_ = [texReg registerTexture:mtex_];

        MetalRenderAPI ra{};
        ra.device   = (__bridge void*)mtex_->device;
        ra.cmdQueue = (__bridge void*)mtex_->cmdQueue;
        ra.texture  = (__bridge void*)mtex_->texture;
        setRenderAPI(&ra);
        setVideoSurfaceSize(width, height);

        // Create PiP layer (SIMPLIFIED - no format description)
        pipLayer = [[PipDisplayLayer alloc] initWithTextureId:texId_ width:width height:height];
        [FvpPlugin registerPipLayer:pipLayer forTextureId:texId_];

        // Render callback with PiP bridge
        __weak TexturePlayer* weakSelf = this;
        setRenderCallback([this, texReg, weakSelf](void* opaque) {
            std::lock_guard<std::mutex> lock(mtex_->mtx);
            renderVideo();

            int64_t tid = this->texId_;
            __unsafe_unretained NSObject<FlutterTextureRegistry>* registry = texReg;

            // Notify Flutter texture
            dispatch_async(dispatch_get_main_queue(), ^{
                [registry textureFrameAvailable:tid];
            });

            // Bridge to PiP (main thread, ULTRA-SIMPLE TIMING)
            TexturePlayer* strongSelf = weakSelf;
            if (strongSelf) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf bridgeFrameToPipLayer];
                });
            }
        });
    }

    ~TexturePlayer() override {
        setRenderCallback(nullptr);
        setVideoSurfaceSize(-1, -1);
        [FvpPlugin unregisterPipLayerForTextureId:texId_];
    }

    int64_t textureId() const { return texId_; }

private:
    void bridgeFrameToPipLayer() {
        if (!pipLayer || !pipLayer.displayLayer) return;

        CVPixelBufferRef pixbuf = mtex_->pixbuf;
        if (!pixbuf) return;

        CMSampleTimingInfo timing = {
            .presentationTimeStamp = kCMTimeInvalid,
            .duration = kCMTimeInvalid,
            .decodeTimeStamp = kCMTimeInvalid
        };

        CMSampleBufferRef sampleBuffer = nil;
        OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(
            kCFAllocatorDefault,
            pixbuf,
            nil,
            &timing,
            &sampleBuffer
        );

        if (status == noErr && sampleBuffer) {
            [pipLayer.displayLayer enqueueSampleBuffer:sampleBuffer];
            CFRelease(sampleBuffer);
        }
    }

    int64_t texId_ = 0;
    MetalTexture* mtex_ = nil;
    PipDisplayLayer *pipLayer = nil;
};

@interface FvpPlugin () {
    std::unordered_map<int64_t, std::shared_ptr<TexturePlayer>> players;
}
@property (readonly, strong, nonatomic) NSObject<FlutterTextureRegistry>* texRegistry;
@property (strong, nonatomic) NSMutableDictionary<NSNumber*, PipDisplayLayer*>* pipLayers;
@end

@implementation FvpPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    id<FlutterBinaryMessenger> messenger = [registrar messenger];
#if TARGET_OS_OSX
#else
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
#endif

    FlutterMethodChannel* channel =
        [FlutterMethodChannel methodChannelWithName:@"fvp"
                                    binaryMessenger:messenger];
    FvpPlugin* instance = [[FvpPlugin alloc] initWithRegistrar:registrar];
#if TARGET_OS_OSX
#else
    [registrar addApplicationDelegate:instance];
#endif
    [registrar publish:instance];
    [registrar addMethodCallDelegate:instance channel:channel];

    SetGlobalOption("MDK_KEY",
        "C03BFF5306AB39058A767105F82697F42A00FE970FB0E641D306DEFF3F220547E5E5377A3C504DC30D547890E71059BC023A4DD91A95474D1F33CA4C26C81B0FC73B00ACF954C6FA75898EFA07D9680B6A00FDF179C0A15381101D01124498AF55B069BD4B0156D5CF5A56DEDE782E5F3930AD47C8F40BFBA379231142E31B0F");
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    self = [super init];
    if (self) {
#if TARGET_OS_OSX
        _texRegistry = registrar.textures;
#else
        _texRegistry = [registrar textures];
#endif
        _pipLayers = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (void)registerPipLayer:(PipDisplayLayer *)layer forTextureId:(int64_t)textureId {
    FvpPlugin *shared = [FvpPlugin sharedInstance];
    [shared.pipLayers setObject:layer forKey:@(textureId)];
}

+ (void)unregisterPipLayerForTextureId:(int64_t)textureId {
    FvpPlugin *shared = [FvpPlugin sharedInstance];
    [shared.pipLayers removeObjectForKey:@(textureId)];
}

+ (PipDisplayLayer *)pipLayerForTextureId:(int64_t)textureId {
    FvpPlugin *shared = [FvpPlugin sharedInstance];
    return [shared.pipLayers objectForKey:@(textureId)];
}

+ (instancetype)sharedInstance {
    static FvpPlugin *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[FvpPlugin alloc] init];
    });
    return shared;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"CreateRT"]) {
        const auto handle = ((NSNumber*)call.arguments[@"player"]).longLongValue;
        const auto width = ((NSNumber*)call.arguments[@"width"]).intValue;
        const auto height = ((NSNumber*)call.arguments[@"height"]).intValue;
        auto player = make_shared<TexturePlayer>(handle, width, height, _texRegistry);
        players[player->textureId()] = player;
        result(@(player->textureId()));
    } else if ([call.method isEqualToString:@"ReleaseRT"]) {
        const auto texId = ((NSNumber*)call.arguments[@"texture"]).longLongValue;
        [_texRegistry unregisterTexture:texId];
        players.erase(texId);
        [FvpPlugin unregisterPipLayerForTextureId:texId];
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
    } else if ([call.method isEqualToString:@"getPipLayerForTexture"]) {
        NSDictionary *args = call.arguments;
        NSNumber *textureIdNum = args[@"textureId"];
        if (!textureIdNum) {
            result([FlutterError errorWithCode:@"INVALID_ARGS" message:@"Missing textureId" details:nil]);
            return;
        }
        int64_t textureId = [textureIdNum longLongValue];

        PipDisplayLayer *pipLayer = [FvpPlugin pipLayerForTextureId:textureId];
        if (pipLayer) {
            result(@YES);
        } else {
            result([FlutterError errorWithCode:@"NO_LAYER" message:@"PiP layer not found" details:nil]);
        }
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  players.clear();
  [_pipLayers removeAllObjects];
}
#if TARGET_OS_OSX
#else
- (void)applicationWillTerminate:(UIApplication *)application {
  players.clear();
  [_pipLayers removeAllObjects];
}
#endif
@end
