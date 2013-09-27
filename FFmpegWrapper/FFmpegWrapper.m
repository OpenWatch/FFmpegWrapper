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
@property (nonatomic) AVRational frameRate;
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

+ (NSString*) stringForAVErrorNumber:(int)errorNumber {
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

+ (NSError*) errorWithCode:(int)errorCode localizedDescription:(NSString*)description {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithCapacity:1];
    if (description) {
        [userInfo setObject:description forKey:NSLocalizedDescriptionKey];
    }
    [userInfo setObject:@(errorCode) forKey:kFFmpegErrorCode];
    return [NSError errorWithDomain:kFFmpegErrorDomain code:errorCode userInfo:userInfo];
}

+ (void) copyInputStream:(FFInputStream*)inputStream outputStream:(FFOutputStream*)outputStream packet:(AVPacket*)packet outputFormatContext:(AVFormatContext*)outputFormatContext
{
    int64_t ost_tb_start_time = av_rescale_q(0, AV_TIME_BASE_Q, outputStream.stream->time_base);
    AVPicture picture;
    AVPacket outputPacket;
    
    av_init_packet(&outputPacket);
    
    if (packet->pts != AV_NOPTS_VALUE)
        outputPacket.pts = av_rescale_q(packet->pts, inputStream.stream->time_base, outputStream.stream->time_base) - ost_tb_start_time;
    else
        outputPacket.pts = AV_NOPTS_VALUE;
    
    if (packet->dts == AV_NOPTS_VALUE)
        outputPacket.dts = av_rescale_q(inputStream.DTS, AV_TIME_BASE_Q, outputStream.stream->time_base);
    else
        outputPacket.dts = av_rescale_q(packet->dts, inputStream.stream->time_base, outputStream.stream->time_base);
    outputPacket.dts -= ost_tb_start_time;
    
    if (outputStream.stream->codec->codec_type == AVMEDIA_TYPE_AUDIO && packet->dts != AV_NOPTS_VALUE) {
        int duration = av_get_audio_frame_duration(inputStream.stream->codec, packet->size);
        if(!duration)
            duration = inputStream.stream->codec->frame_size;
        int64_t filter_in_rescale_delta_last;
        outputPacket.dts = outputPacket.pts = av_rescale_delta(inputStream.stream->time_base, packet->dts,
                                               (AVRational){1, inputStream.stream->codec->sample_rate}, duration, &filter_in_rescale_delta_last,
                                               outputStream.stream->time_base) - ost_tb_start_time;
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
    
    //write_frame(of->ctx, &outputPacket, ost);
    outputStream.stream->codec->frame_number++;
}


/* pkt = NULL means EOF (needed to flush decoder buffers) */
+ (int) processInputStream:(FFInputStream*)inputStream outputStream:(FFOutputStream*)outputStream packet:(AVPacket*)packet outputFormatContext:(AVFormatContext*)outputFormatContext
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
            if (inputStream.frameRate.num) {
                // TODO: Remove work-around for c99-to-c89 issue 7
                AVRational time_base_q = AV_TIME_BASE_Q;
                int64_t next_dts = av_rescale_q(inputStream.nextDTS, time_base_q, av_inv_q(inputStream.frameRate));
                inputStream.nextDTS = av_rescale_q(next_dts + 1, av_inv_q(inputStream.frameRate), time_base_q);
            } else if (packet->duration) {
                inputStream.nextDTS += av_rescale_q(packet->duration, inputStream.stream->time_base, AV_TIME_BASE_Q);
            } else if(inputStream.stream->codec->time_base.num != 0) {
                int ticks= inputStream.stream->parser ? inputStream.stream->parser->repeat_pict + 1 : inputStream.stream->codec->ticks_per_frame;
                inputStream.nextDTS += ((int64_t)AV_TIME_BASE *
                                  inputStream.stream->codec->time_base.num * ticks) /
                inputStream.stream->codec->time_base.den;
            }
            break;
        default:
            break;
    }
    inputStream.PTS = inputStream.DTS;
    inputStream.nextPTS = inputStream.nextDTS;
    
    [[self class] copyInputStream:inputStream outputStream:outputStream packet:packet outputFormatContext:outputFormatContext];
    
    return 0;
}

+ (NSError*) errorForAVErrorNumber:(int)errorNumber {
    NSString *description = [self stringForAVErrorNumber:errorNumber];
    return [self errorWithCode:errorNumber localizedDescription:description];
}

+ (void) handleBadReturnValue:(int)returnValue completionBlock:(FFmpegWrapperCompletionBlock)completionBlock queue:(dispatch_queue_t)queue {
    if (completionBlock) {
        NSError *error = [[self class] errorForAVErrorNumber:returnValue];
        dispatch_async(queue, ^{
            completionBlock(NO, error);
        });
    }
}

- (void) convertInputPath:(NSString*)inputPath outputPath:(NSString*)outputPath options:(NSDictionary*)options progressBlock:(FFmpegWrapperProgressBlock)progressBlock completionBlock:(FFmpegWrapperCompletionBlock)completionBlock {
    dispatch_async(conversionQueue, ^{
        BOOL success = NO;
        int video_sync_method = VSYNC_PASSTHROUGH;
        int audio_sync_method = 0;
        int64_t videoDTS = 0;
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
        unsigned long long totalBytesExpectedToRead = [[inputFileAttributes objectForKey:NSFileSize] unsignedLongLongValue];
        unsigned long long totalBytesRead = 0;
        
        // You can override the detected input format
        AVInputFormat *inputFormat = NULL;
        AVDictionary *inputOptions = NULL;
        AVFormatContext *inputFormatContext = NULL;

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
            [[self class] handleBadReturnValue:openInputValue completionBlock:completionBlock queue:callbackQueue];
            return;
        }
        
        // Open output format context
        AVFormatContext *outputFormatContext = NULL;
        NSString *outputFormatString = [options objectForKey:kFFmpegOutputFormatKey];
        
        int openOutputValue = avformat_alloc_output_context2(&outputFormatContext, NULL, [outputFormatString UTF8String], [outputPath UTF8String]);
        if (openOutputValue < 0) {
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            [[self class] handleBadReturnValue:openInputValue completionBlock:completionBlock queue:callbackQueue];
            return;
        }
        
        NSUInteger inputStreamCount = inputFormatContext->nb_streams;
        
        NSMutableArray *inputStreams = [NSMutableArray arrayWithCapacity: inputStreamCount];
        NSMutableArray *outputStreams = [NSMutableArray arrayWithCapacity:inputStreamCount];
        
        // Set the output streams to be the same as input streams
        int copy_tb = -1;
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
            
            if (inputStream) {
                outputStream->disposition          = inputStream->disposition;
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
                if (!outputFormatContext->oformat->codec_tag ||
                    av_codec_get_id (outputFormatContext->oformat->codec_tag, inputCodecContext->codec_tag) == outputCodecContext->codec_id ||
                    !av_codec_get_tag2(outputFormatContext->oformat->codec_tag, inputCodecContext->codec_id, &codec_tag))
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
            
            outputCodecContext->time_base = inputStream->time_base;
            
            
            if(!(outputFormatContext->oformat->flags & AVFMT_VARIABLE_FPS)
                      && strcmp(outputFormatContext->oformat->name, "mov") && strcmp(outputFormatContext->oformat->name, "mp4") && strcmp(outputFormatContext->oformat->name, "3gp")
                      && strcmp(outputFormatContext->oformat->name, "3g2") && strcmp(outputFormatContext->oformat->name, "psp") && strcmp(outputFormatContext->oformat->name, "ipod")
                      && strcmp(outputFormatContext->oformat->name, "f4v")
                      ) {
                if(   (copy_tb<0 && inputCodecContext->time_base.den
                   && av_q2d(inputCodecContext->time_base)*inputCodecContext->ticks_per_frame > av_q2d(inputStream->time_base)
                   && av_q2d(inputStream->time_base) < 1.0/500)
                   || copy_tb==0){
                    outputCodecContext->time_base = inputCodecContext->time_base;
                    outputCodecContext->time_base.num *= inputCodecContext->ticks_per_frame;
                }
            }
            if (   outputCodecContext->codec_tag == AV_RL32("tmcd")
                && inputCodecContext->time_base.num < inputCodecContext->time_base.den
                && inputCodecContext->time_base.num > 0
                && 121LL*inputCodecContext->time_base.num > inputCodecContext->time_base.den) {
                outputCodecContext->time_base = inputCodecContext->time_base;
            }
            
            if (ffInputStream && !ffOutputStream.frameRate.num)
                ffOutputStream.frameRate = ffInputStream.frameRate;
            if(ffOutputStream.frameRate.num)
                outputCodecContext->time_base = av_inv_q(ffOutputStream.frameRate);
            
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
                    if (inputStream->sample_aspect_ratio.num)
                        sar = inputStream->sample_aspect_ratio;
                    else
                        sar = inputCodecContext->sample_aspect_ratio;
                    outputStream->sample_aspect_ratio = inputCodecContext->sample_aspect_ratio = sar;
                    outputStream->avg_frame_rate = inputStream->avg_frame_rate;                    break;
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
            if (outputFormatContext->oformat->flags & AVFMT_GLOBALHEADER)
                outputCodecContext->flags |= CODEC_FLAG_GLOBAL_HEADER;
        }
        
        /* open the output file, if needed */
        if (!(outputFormatContext->oformat->flags & AVFMT_NOFILE)) {
            int returnValue = avio_open(&outputFormatContext->pb, [outputPath UTF8String], AVIO_FLAG_WRITE);
            if (returnValue < 0) {
                avformat_close_input(&inputFormatContext);
                avformat_free_context(outputFormatContext);
                [[self class] handleBadReturnValue:returnValue completionBlock:completionBlock queue:callbackQueue];
                return;
            }
        }
        
        AVDictionary *options = NULL;
        
        // Write header for output file
        int writeHeaderValue = avformat_write_header(outputFormatContext, &options);
        if (writeHeaderValue < 0) {
            av_dict_free(&options);
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            [[self class] handleBadReturnValue:writeHeaderValue completionBlock:completionBlock queue:callbackQueue];
            return;
        }
        av_dict_free(&options);
        
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
            
            [[self class] processInputStream:ffInputStream outputStream:ffOutputStream packet:packet outputFormatContext:outputFormatContext];
            
            AVStream *outputStream = ffOutputStream.stream;
            
            totalBytesRead += packet->size;
            
            AVCodecContext *outputCodecContext = outputStream->codec;
            
            if ((outputCodecContext->codec_type == AVMEDIA_TYPE_VIDEO && video_sync_method == VSYNC_DROP) ||
                (outputCodecContext->codec_type == AVMEDIA_TYPE_AUDIO && audio_sync_method < 0))
                packet->pts = packet->dts = AV_NOPTS_VALUE;
            
            /*
             * Audio encoders may split the packets --  #frames in != #packets out.
             * But there is no reordering, so we can limit the number of output packets
             * by simply dropping them here.
             * Counting encoded video frames needs to be done separately because of
             * reordering, see do_video_out()
             */
            /*
            if (!(avctx->codec_type == AVMEDIA_TYPE_VIDEO && avctx->codec)) {
                if (ost->frame_number >= ost->max_frames) {
                    av_free_packet(pkt);
                    break;
                }
                ost->frame_number++;
            }
             */
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
                    break;
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
                av_log(NULL, AV_LOG_INFO, "muxer <- type:%s "
                       "pkt_pts:%s pkt_pts_time:%s pkt_dts:%s pkt_dts_time:%s size:%d\n",
                       av_get_media_type_string(outputStream->codec->codec_type),
                       av_ts2str(packet->pts), av_ts2timestr(packet->pts, &outputStream->time_base),
                       av_ts2str(packet->dts), av_ts2timestr(packet->dts, &outputStream->time_base),
                       packet->size
                       );
            }
            
            int writeFrameValue = av_interleaved_write_frame(outputFormatContext, packet);
            if (writeFrameValue < 0) {
                avformat_close_input(&inputFormatContext);
                avformat_free_context(outputFormatContext);
                [[self class] handleBadReturnValue:writeFrameValue completionBlock:completionBlock queue:callbackQueue];
                return;
            }
            
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
            [[self class] handleBadReturnValue:frameReadValue completionBlock:completionBlock queue:callbackQueue];
            return;
        }
        int writeTrailerValue = av_write_trailer(outputFormatContext);
        if (writeTrailerValue < 0) {
            avformat_close_input(&inputFormatContext);
            avformat_free_context(outputFormatContext);
            [[self class] handleBadReturnValue:writeTrailerValue completionBlock:completionBlock queue:callbackQueue];
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
