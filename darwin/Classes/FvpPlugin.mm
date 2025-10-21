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
    TexturePlayer(int64_t handle, int width, int height, NSObject<FlutterTextureRegistry>* texReg)
        : Player(reinterpret_cast<mdkPlayerAPI*>(handle))
    {
        mtex_ = [[MetalTexture alloc] initWithWidth:width height:height];
        texId_ = [texReg registerTexture:mtex_];
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
};


@interface FvpPlugin () {
    unordered_map<int64_t, shared_ptr<TexturePlayer>> players;
    NSMutableDictionary<NSNumber*, AVPictureInPictureController*> *_pipControllers;
}
@property(readonly, strong, nonatomic) NSObject<FlutterTextureRegistry>* texRegistry;
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
    _pipControllers = [NSMutableDictionary new];
#endif
    return self;
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
    } else if ([call.method isEqualToString:@"enablePiP"]) {
        NSDictionary *args = call.arguments;
        NSNumber *textureIdNum = args[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        
        auto it = players.find(textureId);
        if (it == players.end()) {
            result(@NO);
            return;
        }
        shared_ptr<TexturePlayer> texPlayer = it->second;
        
        // Setup AVSampleBufferDisplayLayer for PiP (bridge from mdk::Player)
        AVSampleBufferDisplayLayer *displayLayer = [AVSampleBufferDisplayLayer layer];
        displayLayer.bounds = CGRectMake(0, 0, texPlayer->videoWidth(), texPlayer->videoHeight());
        displayLayer.position = CGPointMake(CGRectGetMidX(displayLayer.bounds), CGRectGetMidY(displayLayer.bounds));
        displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        
        // Hidden dummy view to hold layer
        UIView *dummyView = [UIView new];
        dummyView.hidden = YES;
        [dummyView.layer addSublayer:displayLayer];
        [[UIApplication sharedApplication].keyWindow.rootViewController.view addSubview:dummyView];
        
        // Bridge frames: Set mdk render callback to feed to displayLayer
        texPlayer->setRenderCallback([displayLayer](void* opaque) {
            // Get frame from mdk (adapt from your Metal callback)
            // In callback
            AVFrame *avFrame = getAVFrameFromMdk();  // Adapt from mdk::Player's frame data
            CVPixelBufferRef pixelBuffer;
            CVPixelBufferCreate(kCFAllocatorDefault, avFrame->width, avFrame->height, kCVPixelFormatType_32BGRA, NULL, &pixelBuffer);
            // Copy lines from avFrame->data to pixelBuffer (use av_image_copy_to_buffer or loop)
            for (int plane = 0; plane < 3; plane++) {
            uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane);
            size_t dstStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane);
            uint8_t *src = avFrame->data[plane];
            size_t srcStride = avFrame->linesize[plane];
            for (int h = 0; h < avFrame->height; h++) {
                memcpy(dst + h * dstStride, src + h * srcStride, srcStride);
            }
            }
            CMSampleBufferRef sampleBuffer = NULL;
            // Create CMSampleBuffer from pixelBuffer (timing from mdk timestamp)
            CMSampleTimingInfo timingInfo = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, YES, NULL, NULL, NULL, &timingInfo, &sampleBuffer);
            
            [displayLayer enqueue:sampleBuffer];
            CFRelease(sampleBuffer);
            CFRelease(pixelBuffer);
        });
        
        // Create PiP controller with displayLayer
        AVPictureInPictureController *pipController = [AVPictureInPictureController allocWithContentSource:[AVPictureInPictureControllerContentSource alloc] initWithSampleBufferDisplayLayer:displayLayer placeholderImage:nil]];
        if (pipController) {
            // Store in global map or instance var
            _pipControllers[@(textureId)] = pipController;  // Add NSMutableDictionary * _pipControllers = [NSMutableDictionary new]; at top
            result(@YES);
        } else {
            result(@NO);
        }
    } else if ([call.method isEqualToString:@"enterPipMode"]) {
        NSDictionary *args = call.arguments;
        NSNumber *textureIdNum = args[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        int width = [args[@"width"] intValue];
        int height = [args[@"height"] intValue];
        
        AVPictureInPictureController *pipController = _pipControllers[@(textureId)];
        if (pipController && pipController.isPictureInPicturePossible) {
            [pipController startPictureInPicture];
            result(@YES);
        } else {
            result(@NO);
        }
    } else if ([call.method isEqualToString:@"exitPipMode"]) {
        NSDictionary *args = call.arguments;
        NSNumber *textureIdNum = args[@"textureId"];
        int64_t textureId = [textureIdNum longLongValue];
        
        AVPictureInPictureController *pipController = _pipControllers[@(textureId)];
        if (pipController.isPictureInPictureActive) {
            [pipController stopPictureInPicture];
        }
        result(@YES);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

// ios only, optional. called first in dealloc(texture registry is still alive). plugin instance must be registered via publish
- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  players.clear();
}

#if TARGET_OS_OSX
#else
- (void)applicationWillTerminate:(UIApplication *)application {
  players.clear();
}
#endif
@end
