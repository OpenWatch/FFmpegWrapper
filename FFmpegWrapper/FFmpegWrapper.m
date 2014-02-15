//
//  FFmpegWrapper.m
//  FFmpegWrapper
//
//  Created by Christopher Ballinger on 9/14/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//
//  This file is part of FFmpegWrapper.
//
//  FFmpegWrapper is free software; you can redistribute it and/or
//  modify it under the terms of the GNU Lesser General Public
//  License as published by the Free Software Foundation; either
//  version 2.1 of the License, or (at your option) any later version.
//
//  FFmpegWrapper is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  Lesser General Public License for more details.
//
//  You should have received a copy of the GNU Lesser General Public
//  License along with FFmpegWrapper; if not, write to the Free Software
//  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
//

#import "FFmpegWrapper.h"
#import "libavformat/avformat.h"
#import "libavcodec/avcodec.h"
#import "libavutil/intreadwrite.h"
#import "libavutil/timestamp.h"
#import "libavutil/log.h"

#import "FFInputFile.h"
#import "FFOutputFile.h"
#import "FFInputStream.h"
#import "FFOutputStream.h"
#import "FFBitstreamFilter.h"

#define VSYNC_AUTO       -1
#define VSYNC_PASSTHROUGH 0
#define VSYNC_CFR         1
#define VSYNC_VFR         2
#define VSYNC_DROP        0xff

@implementation FFmpegWrapper
@synthesize conversionQueue, callbackQueue;

- (void) dealloc {
    avformat_network_deinit();
}

- (id) init {
    if (self = [super init]) {
        self.conversionQueue = dispatch_queue_create("ffmpeg conversion queue", NULL);
        self.callbackQueue = dispatch_get_main_queue();
        av_register_all();
        avformat_network_init();
        avcodec_register_all();
#if DEBUG
        av_log_set_level(AV_LOG_VERBOSE);
#else
        av_log_set_level(AV_LOG_QUIET);
#endif

    }
    return self;
}

- (void) setupDirectStreamCopyFromInputFile:(FFInputFile*)inputFile outputFile:(FFOutputFile*)outputFile {
    // Set the output streams to be the same as input streams
    NSUInteger inputStreamCount = inputFile.streams.count;
    for (int i = 0; i < inputStreamCount; i++) {
        FFInputStream *inputStream = [inputFile.streams objectAtIndex:i];
        FFOutputStream *outputStream = [[FFOutputStream alloc] initWithOutputFile:outputFile outputCodec:[inputStream codecName]];
        AVCodecContext *inputCodecContext = inputStream.stream->codec;
        AVCodecContext *outputCodecContext = outputStream.stream->codec;
        avcodec_copy_context(outputCodecContext, inputCodecContext);
    }
}

- (void) finishWithSuccess:(BOOL)success error:(NSError*)error completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    if (completionBlock) {
        dispatch_async(callbackQueue, ^{
            completionBlock(success, error);
        });
    }
}

- (void) convertInputPath:(NSString*)inputPath outputPath:(NSString*)outputPath options:(NSDictionary*)options progressBlock:(FFmpegWrapperProgressBlock)progressBlock completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    dispatch_async(conversionQueue, ^{
        FFInputFile *inputFile = nil;
        FFOutputFile *outputFile = nil;
        NSError *error = nil;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSDictionary *inputFileAttributes = [fileManager attributesOfItemAtPath:inputPath error:&error];
        if (error) {
            [self finishWithSuccess:NO error:error completionBlock:completionBlock];
            return;
        }
        uint64_t totalBytesExpectedToRead = [[inputFileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
        uint64_t totalBytesRead = 0;
        
        // Open the input file for reading
        inputFile = [[FFInputFile alloc] initWithPath:inputPath options:options];
        
        // Open output format context
        outputFile = [[FFOutputFile alloc] initWithPath:outputPath options:options];
        
        // Copy settings from input context to output context for direct stream copy
        [self setupDirectStreamCopyFromInputFile:inputFile outputFile:outputFile];
        
        // Open the output file for writing and write header
        if (![outputFile openFileForWritingWithError:&error]) {
            [self finishWithSuccess:NO error:error completionBlock:completionBlock];
            return;
        }
        if (![outputFile writeHeaderWithError:&error]) {
            [self finishWithSuccess:NO error:error completionBlock:completionBlock];
            return;
        }
        
        FFBitstreamFilter *bitstreamFilter = [[FFBitstreamFilter alloc] initWithFilterName:@"h264_mp4toannexb"];
        [outputFile addBitstreamFilter:bitstreamFilter];
        
        // Read the input file
        BOOL continueReading = YES;
        AVPacket *packet = av_malloc(sizeof(AVPacket));
        while (continueReading) {
            continueReading = [inputFile readFrameIntoPacket:packet error:&error];
            if (error) {
                [self finishWithSuccess:NO error:error completionBlock:completionBlock];
                return;
            }
            if (!continueReading) {
                break;
            }
            
            FFInputStream *inputStream = [inputFile.streams objectAtIndex:packet->stream_index];
            FFOutputStream *outputStream = [outputFile.streams objectAtIndex:packet->stream_index];
            
            packet->pts = av_rescale_q(packet->pts, inputStream.stream->time_base, outputStream.stream->time_base);
            packet->dts = av_rescale_q(packet->dts, inputStream.stream->time_base, outputStream.stream->time_base);
            
            totalBytesRead += packet->size;
            
            if (![outputFile writePacket:packet error:&error]) {
                [self finishWithSuccess:NO error:error completionBlock:completionBlock];
                return;
            }
            
            if (progressBlock) {
                dispatch_async(callbackQueue, ^{
                    progressBlock(packet->size, totalBytesRead, totalBytesExpectedToRead);
                });
            }
            av_free_packet(packet);
        }

        if (![outputFile writeTrailerWithError:&error]) {
            [self finishWithSuccess:NO error:error completionBlock:completionBlock];
            return;
        }
        
        // Yay looks good!
        [self finishWithSuccess:YES error:nil completionBlock:completionBlock];
    });
}

@end
