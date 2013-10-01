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
    }
    return self;
}


- (AVPacket*) copyInputStream:(FFInputStream*)inputStream outputStream:(FFOutputStream*)outputStream packet:(AVPacket*)packet
{
    AVFormatContext *outputFormatContext = outputStream.parentFile.formatContext;
    AVPicture picture;
    AVPacket *outputPacket = av_malloc(sizeof(AVPacket));
    av_init_packet(outputPacket);
    
    //if (!outputStream.frameNumber && !(packet->flags & AV_PKT_FLAG_KEY))
    //    return nil;
    
    if (packet->pts != AV_NOPTS_VALUE)
        outputPacket->pts = av_rescale_q(packet->pts, inputStream.stream->time_base, outputStream.stream->time_base);
    else
        outputPacket->pts = AV_NOPTS_VALUE;
    
    if (packet->dts == AV_NOPTS_VALUE)
        outputPacket->dts = av_rescale_q(inputStream.DTS, AV_TIME_BASE_Q, outputStream.stream->time_base);
    else
        outputPacket->dts = av_rescale_q(packet->dts, inputStream.stream->time_base, outputStream.stream->time_base);
    
    if (outputStream.stream->codec->codec_type == AVMEDIA_TYPE_AUDIO && packet->dts != AV_NOPTS_VALUE) {
        int duration = av_get_audio_frame_duration(inputStream.stream->codec, packet->size);
        if(!duration)
            duration = inputStream.stream->codec->frame_size;
        int64_t filter_in_rescale_delta_last;
        outputPacket->dts = outputPacket->pts = av_rescale_delta(inputStream.stream->time_base, packet->dts,
                                               (AVRational){1, inputStream.stream->codec->sample_rate}, duration, &filter_in_rescale_delta_last,
                                               outputStream.stream->time_base);
        inputStream.filterInRescaleDeltaLast = filter_in_rescale_delta_last;
    }
    
    outputPacket->duration = av_rescale_q(packet->duration, inputStream.stream->time_base, outputStream.stream->time_base);
    outputPacket->flags    = packet->flags;
    
    // FIXME remove the following 2 lines they shall be replaced by the bitstream filters
    if (  outputStream.stream->codec->codec_id != AV_CODEC_ID_H264
        && outputStream.stream->codec->codec_id != AV_CODEC_ID_MPEG1VIDEO
        && outputStream.stream->codec->codec_id != AV_CODEC_ID_MPEG2VIDEO
        && outputStream.stream->codec->codec_id != AV_CODEC_ID_VC1
        ) {
        if (av_parser_change(inputStream.stream->parser, outputStream.stream->codec, &outputPacket->data, &outputPacket->size, packet->data, packet->size, packet->flags & AV_PKT_FLAG_KEY)) {
            outputPacket->buf = av_buffer_create(outputPacket->data, outputPacket->size, av_buffer_default_free, NULL, 0);
            if (!outputPacket->buf) {
                NSLog(@"couldnt allocate packet buffer");
            }
        }
    } else {
        outputPacket->data = packet->data;
        outputPacket->size = packet->size;
    }
    
    if (outputStream.stream->codec->codec_type == AVMEDIA_TYPE_VIDEO && (outputFormatContext->oformat->flags & AVFMT_RAWPICTURE)) {
        /* store AVPicture in AVPacket, as expected by the output format */
        avpicture_fill(&picture, outputPacket->data, outputStream.stream->codec->pix_fmt, outputStream.stream->codec->width, outputStream.stream->codec->height);
        outputPacket->data = (uint8_t *)&picture;
        outputPacket->size = sizeof(AVPicture);
        outputPacket->flags |= AV_PKT_FLAG_KEY;
    }
    
    return outputPacket;
}


/* pkt = NULL means EOF (needed to flush decoder buffers) */
- (AVPacket*) processInputStream:(FFInputStream*)inputStream outputStream:(FFOutputStream*)outputStream packet:(AVPacket*)packet
{
    if (!inputStream.sawFirstTS) {
        inputStream.DTS = inputStream.stream->avg_frame_rate.num ? - inputStream.stream->codec->has_b_frames * AV_TIME_BASE / av_q2d(inputStream.stream->avg_frame_rate) : 0;
        inputStream.PTS = 0;
        if (packet != NULL && packet->pts != AV_NOPTS_VALUE) {
            inputStream.DTS += av_rescale_q(packet->pts, inputStream.stream->time_base, AV_TIME_BASE_Q);
            inputStream.PTS = inputStream.DTS; //unused but better to set it to a value thats not totally wrong
        }
        inputStream.sawFirstTS = YES;
    }
    
    if (inputStream.nextDTS == AV_NOPTS_VALUE)
        inputStream.nextDTS = inputStream.DTS;
    if (inputStream.nextPTS == AV_NOPTS_VALUE)
        inputStream.nextPTS = inputStream.PTS;
    
    if (packet->dts != AV_NOPTS_VALUE) {
        inputStream.nextDTS = inputStream.DTS = av_rescale_q(packet->dts, inputStream.stream->time_base, AV_TIME_BASE_Q);
        inputStream.nextPTS = inputStream.PTS = inputStream.DTS;
    }
    
    /* handle stream copy */
    inputStream.DTS = inputStream.nextDTS;
    switch (inputStream.stream->codec->codec_type) {
        case AVMEDIA_TYPE_AUDIO:
            inputStream.nextDTS += ((int64_t)AV_TIME_BASE * inputStream.stream->codec->frame_size) /
            inputStream.stream->codec->sample_rate;
            break;
        case AVMEDIA_TYPE_VIDEO:
            if (packet->duration) {
                inputStream.nextDTS += av_rescale_q(packet->duration, inputStream.stream->time_base, AV_TIME_BASE_Q);
            }
            break;
        default:
            break;
    }
    inputStream.PTS = inputStream.DTS;
    inputStream.nextPTS = inputStream.nextDTS;
    
    return [self copyInputStream:inputStream outputStream:outputStream packet:packet];
}

- (void) setupDirectStreamCopyFromInputFile:(FFInputFile*)inputFile outputFile:(FFOutputFile*)outputFile {
    // Set the output streams to be the same as input streams
    NSUInteger inputStreamCount = inputFile.streams.count;
    for (int i = 0; i < inputStreamCount; i++) {
        FFInputStream *inputStream = [inputFile.streams objectAtIndex:i];
        FFOutputStream *outputStream = [[FFOutputStream alloc] initWithOutputFile:outputFile outputCodec:[inputStream codecName]];
        
        AVCodecContext *inputCodecContext = inputStream.stream->codec;
        AVCodecContext *outputCodecContext = outputStream.stream->codec;
        
        if (inputStream) {
            outputStream.stream->disposition          = inputStream.stream->disposition;
            outputCodecContext->bits_per_raw_sample    = inputCodecContext->bits_per_raw_sample;
            outputCodecContext->chroma_sample_location = inputCodecContext->chroma_sample_location;
        }
        
        AVRational sar;
        uint64_t extra_size;
        
        extra_size = (uint64_t)inputCodecContext->extradata_size + FF_INPUT_BUFFER_PADDING_SIZE;
        
        if (extra_size > INT_MAX) {
            //return AVERROR(EINVAL);
            return;
        }
        
        // if stream_copy is selected, no need to decode or encode
        outputCodecContext->codec_id   = inputCodecContext->codec_id;
        outputCodecContext->codec_type = inputCodecContext->codec_type;
        
        if (!outputCodecContext->codec_tag) {
            unsigned int codec_tag;
            if (!outputFile.formatContext->oformat->codec_tag ||
                av_codec_get_id (outputFile.formatContext->oformat->codec_tag, inputCodecContext->codec_tag) == outputCodecContext->codec_id ||
                !av_codec_get_tag2(outputFile.formatContext->oformat->codec_tag, inputCodecContext->codec_id, &codec_tag))
                outputCodecContext->codec_tag = inputCodecContext->codec_tag;
        }
        
        outputCodecContext->bit_rate       = inputCodecContext->bit_rate;
        outputCodecContext->rc_max_rate    = inputCodecContext->rc_max_rate;
        outputCodecContext->rc_buffer_size = inputCodecContext->rc_buffer_size;
        outputCodecContext->field_order    = inputCodecContext->field_order;
        outputCodecContext->extradata      = av_mallocz(extra_size);
        if (!outputCodecContext->extradata) {
            // return AVERROR(ENOMEM);
            return;
        }
        memcpy(outputCodecContext->extradata, inputCodecContext->extradata, inputCodecContext->extradata_size);
        outputCodecContext->extradata_size= inputCodecContext->extradata_size;
        outputCodecContext->bits_per_coded_sample  = inputCodecContext->bits_per_coded_sample;
        
        outputCodecContext->time_base = inputStream.stream->time_base;
        
        av_reduce(&outputCodecContext->time_base.num, &outputCodecContext->time_base.den,
                  outputCodecContext->time_base.num, outputCodecContext->time_base.den, INT_MAX);
        
        switch (outputCodecContext->codec_type) {
            case AVMEDIA_TYPE_AUDIO:
                outputCodecContext->channel_layout     = inputCodecContext->channel_layout;
                outputCodecContext->sample_rate        = inputCodecContext->sample_rate;
                outputCodecContext->channels           = inputCodecContext->channels;
                outputCodecContext->frame_size         = inputCodecContext->frame_size;
                outputCodecContext->audio_service_type = inputCodecContext->audio_service_type;
                outputCodecContext->block_align        = inputCodecContext->block_align;
                if((outputCodecContext->block_align == 1 || outputCodecContext->block_align == 1152 || outputCodecContext->block_align == 576) && outputCodecContext->codec_id == AV_CODEC_ID_MP3)
                    outputCodecContext->block_align= 0;
                if(outputCodecContext->codec_id == AV_CODEC_ID_AC3)
                    outputCodecContext->block_align= 0;
                break;
            case AVMEDIA_TYPE_VIDEO:
                outputCodecContext->pix_fmt            = inputCodecContext->pix_fmt;
                outputCodecContext->width              = inputCodecContext->width;
                outputCodecContext->height             = inputCodecContext->height;
                outputCodecContext->has_b_frames       = inputCodecContext->has_b_frames;
                if (inputStream.stream->sample_aspect_ratio.num)
                    sar = inputStream.stream->sample_aspect_ratio;
                else
                    sar = inputCodecContext->sample_aspect_ratio;
                outputStream.stream->sample_aspect_ratio = inputCodecContext->sample_aspect_ratio = sar;
                outputStream.stream->avg_frame_rate = inputStream.stream->avg_frame_rate;                    break;
            case AVMEDIA_TYPE_SUBTITLE:
                outputCodecContext->width  = inputCodecContext->width;
                outputCodecContext->height = inputCodecContext->height;
                break;
            case AVMEDIA_TYPE_DATA:
            case AVMEDIA_TYPE_ATTACHMENT:
                break;
            default:
                abort();
        }
        /* Some formats want stream headers to be separate. */
        if (outputFile.formatContext->oformat->flags & AVFMT_GLOBALHEADER)
            outputCodecContext->flags |= CODEC_FLAG_GLOBAL_HEADER;
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
            
            
            [inputStream scaleInputPacketTimeScale:packet];
            AVPacket *outputPacket = [self processInputStream:inputStream outputStream:outputStream packet:packet];
            
            
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
            av_free_packet(outputPacket);
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
