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


NSString const *kFFmpegInputFormatKey = @"kFFmpegInputFormatKey";
NSString const *kFFmpegOutputFormatKey = @"kFFmpegOutputFormatKey";
static NSString * const kFFmpegErrorDomain = @"org.ffmpeg.FFmpeg";
static NSString * const kFFmpegErrorCode = @"kFFmpegErrorCode";

#define VSYNC_AUTO       -1
#define VSYNC_PASSTHROUGH 0
#define VSYNC_CFR         1
#define VSYNC_VFR         2
#define VSYNC_DROP        0xff

@interface FFStream : NSObject
//@property (nonatomic) AVRational frameRate;
@property (nonatomic) AVStream *stream;
- (id) initWithStream:(AVStream*)newStream;
@end

@implementation FFStream
@synthesize stream;
- (id) initWithStream:(AVStream *)newStream {
    if (self = [super init]) {
        self.stream = newStream;
    }
    return self;
}
@end

@interface FFInputStream : FFStream
/* predicted dts of the next packet read for this stream or (when there are
 * several frames in a packet) of the next frame in current packet (in AV_TIME_BASE units) */
@property (nonatomic) int64_t       nextDTS;
@property (nonatomic) int64_t       DTS;       ///< dts of the last packet read for this stream (in AV_TIME_BASE units)

@property (nonatomic) int64_t       nextPTS;  ///< synthetic pts for the next decode frame (in AV_TIME_BASE units)
@property (nonatomic) int64_t       PTS;       ///< current pts of the decoded frame  (in AV_TIME_BASE units)
@property (nonatomic) int64_t filterInRescaleDeltaLast;

@property (nonatomic) BOOL sawFirstTS;
@end

@implementation FFInputStream
@synthesize nextDTS, DTS, nextPTS, PTS;
- (id) initWithStream:(AVStream *)newStream {
    if (self = [super initWithStream:newStream]) {
        self.nextPTS = AV_NOPTS_VALUE;
        self.PTS = AV_NOPTS_VALUE;
        self.nextDTS = AV_NOPTS_VALUE;
        self.DTS = AV_NOPTS_VALUE;
        self.filterInRescaleDeltaLast = AV_NOPTS_VALUE;
        self.sawFirstTS = NO;
    }
    return self;
}
@end

@interface FFOutputStream : FFStream
@property (nonatomic) int64_t lastMuxDTS;
@property (nonatomic) int frameNumber;
@end

@implementation FFOutputStream
@synthesize lastMuxDTS, frameNumber;
- (id) initWithStream:(AVStream *)newStream {
    if (self = [super initWithStream:newStream]) {
        self.lastMuxDTS = AV_NOPTS_VALUE;
        self.frameNumber = 0;
    }
    return self;
}
@end

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

- (NSString*) stringForAVErrorNumber:(int)errorNumber {
    NSString *errorString = nil;
    char *errorBuffer = malloc(sizeof(char) * AV_ERROR_MAX_STRING_SIZE);
    
    int value = av_strerror(errorNumber, errorBuffer, AV_ERROR_MAX_STRING_SIZE);
    if (value != 0) {
        return nil;
    }
    errorString = [NSString stringWithUTF8String:errorBuffer];
    free(errorBuffer);
    return errorString;
}

- (NSError*) errorWithCode:(int)errorCode localizedDescription:(NSString*)description {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:1];
    if (description) {
        [userInfo setObject:description forKey:NSLocalizedDescriptionKey];
    }
    [userInfo setObject:@(errorCode) forKey:kFFmpegErrorCode];
    return [NSError errorWithDomain:kFFmpegErrorDomain code:errorCode userInfo:userInfo];
}

- (AVPacket) copyInputStream:(FFInputStream*)inputStream outputStream:(FFOutputStream*)outputStream packet:(AVPacket*)packet outputFormatContext:(AVFormatContext*)outputFormatContext
{
    AVPicture picture;
    AVPacket outputPacket;
    
    av_init_packet(&outputPacket);
    
    if (packet->pts != AV_NOPTS_VALUE)
        outputPacket.pts = av_rescale_q(packet->pts, inputStream.stream->time_base, outputStream.stream->time_base);
    else
        outputPacket.pts = AV_NOPTS_VALUE;
    
    if (packet->dts == AV_NOPTS_VALUE)
        outputPacket.dts = av_rescale_q(inputStream.DTS, AV_TIME_BASE_Q, outputStream.stream->time_base);
    else
        outputPacket.dts = av_rescale_q(packet->dts, inputStream.stream->time_base, outputStream.stream->time_base);
    
    if (outputStream.stream->codec->codec_type == AVMEDIA_TYPE_AUDIO && packet->dts != AV_NOPTS_VALUE) {
        int duration = av_get_audio_frame_duration(inputStream.stream->codec, packet->size);
        if(!duration)
            duration = inputStream.stream->codec->frame_size;
        int64_t filter_in_rescale_delta_last;
        outputPacket.dts = outputPacket.pts = av_rescale_delta(inputStream.stream->time_base, packet->dts,
                                               (AVRational){1, inputStream.stream->codec->sample_rate}, duration, &filter_in_rescale_delta_last,
                                               outputStream.stream->time_base);
        inputStream.filterInRescaleDeltaLast = filter_in_rescale_delta_last;
    }
    
    outputPacket.duration = av_rescale_q(packet->duration, inputStream.stream->time_base, outputStream.stream->time_base);
    outputPacket.flags    = packet->flags;
    
    // FIXME remove the following 2 lines they shall be replaced by the bitstream filters
    if (  outputStream.stream->codec->codec_id != AV_CODEC_ID_H264
        && outputStream.stream->codec->codec_id != AV_CODEC_ID_MPEG1VIDEO
        && outputStream.stream->codec->codec_id != AV_CODEC_ID_MPEG2VIDEO
        && outputStream.stream->codec->codec_id != AV_CODEC_ID_VC1
        ) {
        if (av_parser_change(inputStream.stream->parser, outputStream.stream->codec, &outputPacket.data, &outputPacket.size, packet->data, packet->size, packet->flags & AV_PKT_FLAG_KEY)) {
            outputPacket.buf = av_buffer_create(outputPacket.data, outputPacket.size, av_buffer_default_free, NULL, 0);
            if (!outputPacket.buf) {
                NSLog(@"couldnt allocate packet buffer");
            }
        }
    } else {
        outputPacket.data = packet->data;
        outputPacket.size = packet->size;
    }
    
    if (outputStream.stream->codec->codec_type == AVMEDIA_TYPE_VIDEO && (outputFormatContext->oformat->flags & AVFMT_RAWPICTURE)) {
        /* store AVPicture in AVPacket, as expected by the output format */
        avpicture_fill(&picture, outputPacket.data, outputStream.stream->codec->pix_fmt, outputStream.stream->codec->width, outputStream.stream->codec->height);
        outputPacket.data = (uint8_t *)&picture;
        outputPacket.size = sizeof(AVPicture);
        outputPacket.flags |= AV_PKT_FLAG_KEY;
    }
    
    return outputPacket;
}


/* pkt = NULL means EOF (needed to flush decoder buffers) */
- (AVPacket) processInputStream:(FFInputStream*)inputStream outputStream:(FFOutputStream*)outputStream packet:(AVPacket*)packet outputFormatContext:(AVFormatContext*)outputFormatContext
{
    AVPacket avpkt;
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
    
    if (packet == NULL) {
        /* EOF handling */
        av_init_packet(&avpkt);
        avpkt.data = NULL;
        avpkt.size = 0;
        //goto handle_eof;
    } else {
        avpkt = *packet;
    }
    
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
            inputStream.nextDTS += av_rescale_q(packet->duration, inputStream.stream->time_base, AV_TIME_BASE_Q);
            break;
        default:
            break;
    }
    inputStream.PTS = inputStream.DTS;
    inputStream.nextPTS = inputStream.nextDTS;
    
    return [self copyInputStream:inputStream outputStream:outputStream packet:packet outputFormatContext:outputFormatContext];
}

- (NSError*) errorForAVErrorNumber:(int)errorNumber {
    NSString *description = [self stringForAVErrorNumber:errorNumber];
    return [self errorWithCode:errorNumber localizedDescription:description];
}

- (void) handleBadReturnValue:(int)returnValue completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    if (completionBlock) {
        NSError *error = [[self class] errorForAVErrorNumber:returnValue];
        dispatch_async(self.callbackQueue, ^{
            completionBlock(NO, error);
        });
    }
}

- (AVFormatContext*) formatContextForInputPath:(NSString*)inputPath options:(NSDictionary*)options completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    // You can override the detected input format
    AVFormatContext *inputFormatContext = NULL;
    AVInputFormat *inputFormat = NULL;
    AVDictionary *inputOptions = NULL;
    
    NSString *inputFormatString = [options objectForKey:kFFmpegInputFormatKey];
    if (inputFormatString) {
        inputFormat = av_find_input_format([inputFormatString UTF8String]);
    }
    
    // It's possible to send more options to the parser
    // av_dict_set(&inputOptions, "video_size", "640x480", 0);
    // av_dict_set(&inputOptions, "pixel_format", "rgb24", 0);
    // av_dict_free(&inputOptions); // Don't forget to free
    
    int openInputValue = avformat_open_input(&inputFormatContext, [inputPath UTF8String], inputFormat, &inputOptions);
    if (openInputValue != 0) {
        avformat_close_input(&inputFormatContext);
        [self handleBadReturnValue:openInputValue completionBlock:completionBlock];
        return nil;
    }
    
    int streamInfoValue = avformat_find_stream_info(inputFormatContext, NULL);
    if (streamInfoValue < 0) {
        avformat_close_input(&inputFormatContext);
        [self handleBadReturnValue:streamInfoValue completionBlock:completionBlock];
        return nil;
    }
    return inputFormatContext;
}

- (AVFormatContext*) formatContextForOutputPath:(NSString*)outputPath options:(NSDictionary*)options completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    AVFormatContext *outputFormatContext = NULL;
    NSString *outputFormatString = [options objectForKey:kFFmpegOutputFormatKey];
    
    int openOutputValue = avformat_alloc_output_context2(&outputFormatContext, NULL, [outputFormatString UTF8String], [outputPath UTF8String]);
    if (openOutputValue < 0) {
        avformat_free_context(outputFormatContext);
        [self handleBadReturnValue:openOutputValue completionBlock:completionBlock];
        return nil;
    }
    return outputFormatContext;
}

- (void) setupDirectStreamCopyFromInputFormatContext:(AVFormatContext*)inputFormatContext outputFormatContext:(AVFormatContext*)outputFormatContext inputStreams:(NSMutableArray*)inputStreams outputStreams:(NSMutableArray*)outputStreams {
    // Set the output streams to be the same as input streams
    NSUInteger inputStreamCount = inputFormatContext->nb_streams;
    for (int i = 0; i < inputStreamCount; i++) {
        AVStream *inputStream = inputFormatContext->streams[i];
        FFInputStream *ffInputStream = [[FFInputStream alloc] initWithStream:inputStream];
        [inputStreams addObject:ffInputStream];
        AVCodecContext *inputCodecContext = inputStream->codec;
        AVCodec *outputCodec = avcodec_find_encoder(inputCodecContext->codec_id);
        AVStream *outputStream = avformat_new_stream(outputFormatContext, outputCodec);
        FFOutputStream *ffOutputStream = [[FFOutputStream alloc] initWithStream:outputStream];
        [outputStreams addObject:ffOutputStream];
        
        AVCodecContext *outputCodecContext = outputStream->codec;
        avcodec_copy_context(outputCodecContext, inputCodecContext);
    }
}

// Returns YES if successful
- (BOOL) openOutputPath:(NSString*)outputPath outputFormatContext:(AVFormatContext*)outputFormatContext completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    
    /* open the output file, if needed */
    if (!(outputFormatContext->oformat->flags & AVFMT_NOFILE)) {
        int returnValue = avio_open(&outputFormatContext->pb, [outputPath UTF8String], AVIO_FLAG_WRITE);
        if (returnValue < 0) {
            [self handleBadReturnValue:returnValue completionBlock:completionBlock];
            return NO;
        }
    }
    
    AVDictionary *options = NULL;
    
    // Write header for output file
    int writeHeaderValue = avformat_write_header(outputFormatContext, &options);
    if (writeHeaderValue < 0) {
        av_dict_free(&options);
        [self handleBadReturnValue:writeHeaderValue completionBlock:completionBlock];
        return NO;
    }
    av_dict_free(&options);
    return YES;
}

- (BOOL) writePacket:(AVPacket*)packet outputStream:(FFOutputStream*)ffOutputStream bitstreamFilterContext:(AVBitStreamFilterContext*)bitstreamFilterContext outputFormatContext:(AVFormatContext*)outputFormatContext {
    int video_sync_method = VSYNC_PASSTHROUGH;
    int audio_sync_method = 0;
    
    AVStream *outputStream = ffOutputStream.stream;
    
    
    AVCodecContext *outputCodecContext = outputStream->codec;
    
    if ((outputCodecContext->codec_type == AVMEDIA_TYPE_VIDEO && video_sync_method == VSYNC_DROP) ||
        (outputCodecContext->codec_type == AVMEDIA_TYPE_AUDIO && audio_sync_method < 0))
        packet->pts = packet->dts = AV_NOPTS_VALUE;
    
    if (outputCodecContext->codec_type == AVMEDIA_TYPE_VIDEO) {
        AVPacket newPacket = *packet;
        int a = av_bitstream_filter_filter(bitstreamFilterContext, outputCodecContext, NULL,
                                           &newPacket.data, &newPacket.size,
                                           packet->data, packet->size,
                                           packet->flags & AV_PKT_FLAG_KEY);
        if(a == 0 && newPacket.data != packet->data && newPacket.destruct) {
            uint8_t *t = av_malloc(newPacket.size + FF_INPUT_BUFFER_PADDING_SIZE); //the new should be a subset of the old so cannot overflow
            if(t) {
                memcpy(t, newPacket.data, newPacket.size);
                memset(t + newPacket.size, 0, FF_INPUT_BUFFER_PADDING_SIZE);
                newPacket.data = t;
                newPacket.buf = NULL;
                a = 1;
            } else {
                a = AVERROR(ENOMEM);
            }
            
        }
        if (a > 0) {
            av_free_packet(packet);
            newPacket.buf = av_buffer_create(newPacket.data, newPacket.size,
                                             av_buffer_default_free, NULL, 0);
            if (!newPacket.buf) {
                NSLog(@"new packet buffer couldnt be allocated");
            }
            
        } else if (a < 0) {
            NSLog(@"FFmpeg Error: Failed to open bitstream filter %s for stream %d with codec %s", bitstreamFilterContext->filter->name, packet->stream_index,
                  outputCodecContext->codec ? outputCodecContext->codec->name : "copy");
            return NO;
        }
        *packet = newPacket;
    }
    
    if (!(outputFormatContext->oformat->flags & AVFMT_NOTIMESTAMPS) &&
        (outputCodecContext->codec_type == AVMEDIA_TYPE_AUDIO || outputCodecContext->codec_type == AVMEDIA_TYPE_VIDEO) &&
        packet->dts != AV_NOPTS_VALUE &&
        ffOutputStream.lastMuxDTS != AV_NOPTS_VALUE) {
        int64_t max = ffOutputStream.lastMuxDTS + !(outputFormatContext->oformat->flags & AVFMT_TS_NONSTRICT);
        if (packet->dts < max) {
            int loglevel = max - packet->dts > 2 || outputCodecContext->codec_type == AVMEDIA_TYPE_VIDEO ? AV_LOG_WARNING : AV_LOG_DEBUG;
            av_log(outputFormatContext, loglevel, "Non-monotonous DTS in output stream "
                   "%d:%d; previous: %"PRId64", current: %"PRId64"; ",
                   0, outputStream->index, ffOutputStream.lastMuxDTS, packet->dts);
            
            av_log(outputFormatContext, loglevel, "changing to %"PRId64". This may result "
                   "in incorrect timestamps in the output file.\n",
                   max);
            if(packet->pts >= packet->dts)
                packet->pts = FFMAX(packet->pts, max);
            packet->dts = max;
        }
    }
    ffOutputStream.lastMuxDTS = packet->dts;
    
    // Not sure if commenting this out will have side-effects
    //pkt->stream_index = ost->index;
    BOOL debug_ts = TRUE;
    if (debug_ts) {
        NSLog(@"muxer <- type:%s "
                   "pkt_pts:%s pkt_pts_time:%s pkt_dts:%s pkt_dts_time:%s size:%d\n",
                   av_get_media_type_string(outputStream->codec->codec_type),
                   av_ts2str(packet->pts), av_ts2timestr(packet->pts, &outputStream->time_base),
                   av_ts2str(packet->dts), av_ts2timestr(packet->dts, &outputStream->time_base),
                   packet->size);
    }
    
    int writeFrameValue = av_interleaved_write_frame(outputFormatContext, packet);
    if (writeFrameValue < 0) {
        //avformat_close_input(&inputFormatContext);
        avformat_free_context(outputFormatContext);
        //[self handleBadReturnValue:writeFrameValue completionBlock:completionBlock];
        return NO;
    }
    outputStream->codec->frame_number++;
    return YES;
}

- (void) convertInputPath:(NSString*)inputPath outputPath:(NSString*)outputPath options:(NSDictionary*)options progressBlock:(FFmpegWrapperProgressBlock)progressBlock completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    dispatch_async(conversionQueue, ^{
        BOOL success = NO;
        NSError *error = nil;
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSDictionary *inputFileAttributes = [fileManager attributesOfItemAtPath:inputPath error:&error];
        if (error) {
            if (completionBlock) {
                dispatch_async(callbackQueue, ^{
                    completionBlock(success, error);
                });
            }
            return;
        }
        uint64_t totalBytesExpectedToRead = [[inputFileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
        uint64_t totalBytesRead = 0;
        
        // Open the input file for reading
        AVFormatContext *inputFormatContext = [self formatContextForInputPath:inputPath options:options completionBlock:completionBlock];
        if (!inputFormatContext) {
            return;
        }
        
        // Open output format context
        AVFormatContext *outputFormatContext = [self formatContextForOutputPath:outputPath options:options completionBlock:completionBlock];
        if (!outputFormatContext) {
            avformat_close_input(&inputFormatContext);
            return;
        }
        
        // Copy settings from input context to output context for direct stream copy
        NSUInteger inputStreamCount = inputFormatContext->nb_streams;
        NSMutableArray *inputStreams = [NSMutableArray arrayWithCapacity:inputStreamCount];
        NSMutableArray *outputStreams = [NSMutableArray arrayWithCapacity:inputStreamCount];
        [self setupDirectStreamCopyFromInputFormatContext:inputFormatContext outputFormatContext:outputFormatContext inputStreams:inputStreams outputStreams:outputStreams];
        
        // Open the output file for writing and write header
        if (![self openOutputPath:outputPath outputFormatContext:outputFormatContext completionBlock:completionBlock]) {
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            return;
        }
        
        AVBitStreamFilterContext *bitstreamFilterContext = av_bitstream_filter_init("h264_mp4toannexb");
        
        // Read the input file
        BOOL continueReading = YES;
        AVPacket *packet = av_malloc(sizeof(AVPacket));
        int frameReadValue = -1;
        while (continueReading) {
            frameReadValue = av_read_frame(inputFormatContext, packet);
            if (frameReadValue != 0) {
                continueReading = NO;
                av_free_packet(packet);
                break;
            }
            
            FFOutputStream *ffOutputStream = [outputStreams objectAtIndex:packet->stream_index];
            FFInputStream *ffInputStream = [inputStreams objectAtIndex:packet->stream_index];
            
            AVPacket outputPacket = [self processInputStream:ffInputStream outputStream:ffOutputStream packet:packet outputFormatContext:outputFormatContext];
            
            totalBytesRead += packet->size;
            
            [self writePacket:packet outputStream:ffOutputStream bitstreamFilterContext:bitstreamFilterContext outputFormatContext:outputFormatContext];
            
            if (progressBlock) {
                dispatch_async(callbackQueue, ^{
                    progressBlock(packet->size, totalBytesRead, totalBytesExpectedToRead);
                });
            }
            av_free_packet(packet);
        }
        if (frameReadValue < 0 && frameReadValue != AVERROR_EOF) {
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            [self handleBadReturnValue:frameReadValue completionBlock:completionBlock];
            return;
        }
        int writeTrailerValue = av_write_trailer(outputFormatContext);
        if (writeTrailerValue < 0) {
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            [self handleBadReturnValue:writeTrailerValue completionBlock:completionBlock];
            return;
        }
        
        // Yay looks good!
        avformat_close_input(&inputFormatContext);
        avformat_free_context(outputFormatContext);
        success = YES;
        error = nil;
        if (completionBlock) {
            dispatch_async(callbackQueue, ^{
                completionBlock(success, error);
            });
        }
    });
}

@end
