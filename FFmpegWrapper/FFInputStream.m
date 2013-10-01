//
//  FFInputStream.m
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFInputStream.h"
#import "FFInputFile.h"

#import "libavutil/timestamp.h"

@implementation FFInputStream
@synthesize nextDTS, DTS, nextPTS, PTS;

- (id) initWithInputFile:(FFInputFile*)newInputFile stream:(AVStream*)newStream {
    if (self = [super initWithFile:newInputFile]) {
        self.nextPTS = AV_NOPTS_VALUE;
        self.PTS = AV_NOPTS_VALUE;
        self.nextDTS = AV_NOPTS_VALUE;
        self.DTS = AV_NOPTS_VALUE;
        self.filterInRescaleDeltaLast = AV_NOPTS_VALUE;
        self.sawFirstTS = NO;
        self.wrapCorrectionDone = NO;
        self.stream = newStream;
    }
    return self;
}

- (void) scaleInputPacketTimeScale:(AVPacket *)packet {
    FFInputFile *inputFile = (FFInputFile*)self.parentFile;
    AVFormatContext *inputFormatContext = inputFile.formatContext;
    FFInputStream *inputStream = self;

    BOOL do_pkt_dump = YES;
    BOOL do_hex_dump = NO;
    BOOL debug_ts = YES;
    if (do_pkt_dump) {
        av_pkt_dump_log2(NULL, AV_LOG_DEBUG, packet, do_hex_dump,
                         inputFormatContext->streams[packet->stream_index]);
    }
    
    if (debug_ts) {
        av_log(NULL, AV_LOG_INFO, "demuxer -> type:%s "
               "next_dts:%s next_dts_time:%s next_pts:%s next_pts_time:%s pkt_pts:%s pkt_pts_time:%s pkt_dts:%s pkt_dts_time:%s off:%s off_time:%s\n", av_get_media_type_string(inputStream.stream->codec->codec_type),
               av_ts2str(inputStream.nextDTS), av_ts2timestr(inputStream.nextDTS, &AV_TIME_BASE_Q),
               av_ts2str(inputStream.nextPTS), av_ts2timestr(inputStream.nextPTS, &AV_TIME_BASE_Q),
               av_ts2str(packet->pts), av_ts2timestr(packet->pts, &inputStream.stream->time_base),
               av_ts2str(packet->dts), av_ts2timestr(packet->dts, &inputStream.stream->time_base),
               av_ts2str(inputFile.timestampOffset),
               av_ts2timestr(inputFile.timestampOffset, &AV_TIME_BASE_Q));
    }
    
    if(!inputStream.wrapCorrectionDone && inputFormatContext->start_time != AV_NOPTS_VALUE && inputStream.stream->pts_wrap_bits < 64){
        int64_t stime, stime2;
        // Correcting starttime based on the enabled streams
        // FIXME this ideally should be done before the first use of starttime but we do not know which are the enabled streams at that point.
        //       so we instead do it here as part of discontinuity handling
        if (   inputStream.nextDTS == AV_NOPTS_VALUE
            && inputFile.timestampOffset == -inputFormatContext->start_time
            && (inputFormatContext->iformat->flags & AVFMT_TS_DISCONT)) {
            int64_t new_start_time = INT64_MAX;
            for (int i = 0; i<inputFormatContext->nb_streams; i++) {
                AVStream *st = inputFormatContext->streams[i];
                if(st->discard == AVDISCARD_ALL || st->start_time == AV_NOPTS_VALUE)
                    continue;
                new_start_time = FFMIN(new_start_time, av_rescale_q(st->start_time, st->time_base, AV_TIME_BASE_Q));
            }
            if (new_start_time > inputFormatContext->start_time) {
                NSLog(@"Correcting start time by %"PRId64"\n", new_start_time - inputFormatContext->start_time);
                inputFile.timestampOffset = -new_start_time;
            }
        }
        
        stime = av_rescale_q(inputFormatContext->start_time, AV_TIME_BASE_Q, inputStream.stream->time_base);
        stime2= stime + (1ULL<<inputStream.stream->pts_wrap_bits);
        inputStream.wrapCorrectionDone = YES;
        
        if(stime2 > stime && packet->dts != AV_NOPTS_VALUE && packet->dts > stime + (1LL<<(inputStream.stream->pts_wrap_bits-1))) {
            packet->dts -= 1ULL<<inputStream.stream->pts_wrap_bits;
            inputStream.wrapCorrectionDone = NO;
        }
        if(stime2 > stime && packet->pts != AV_NOPTS_VALUE && packet->pts > stime + (1LL<<(inputStream.stream->pts_wrap_bits-1))) {
            packet->pts -= 1ULL<<inputStream.stream->pts_wrap_bits;
            inputStream.wrapCorrectionDone = NO;
        }
    }
    
    if (packet->dts != AV_NOPTS_VALUE)
        packet->dts += av_rescale_q(inputFile.timestampOffset, AV_TIME_BASE_Q, inputStream.stream->time_base);
    if (packet->pts != AV_NOPTS_VALUE)
        packet->pts += av_rescale_q(inputFile.timestampOffset, AV_TIME_BASE_Q, inputStream.stream->time_base);
    
    if (packet->pts != AV_NOPTS_VALUE)
        packet->pts *= inputStream.timestampScale;
    if (packet->dts != AV_NOPTS_VALUE)
        packet->dts *= inputStream.timestampScale;
    
    BOOL copy_ts = YES;
    float dts_delta_threshold = 0.0f;
    float dts_error_threshold = 0.0f;
    
    if (packet->dts != AV_NOPTS_VALUE && inputStream.nextDTS == AV_NOPTS_VALUE && !copy_ts
        && (inputFormatContext->iformat->flags & AVFMT_TS_DISCONT) && inputFile.lastTimestamp != AV_NOPTS_VALUE) {
        int64_t pkt_dts = av_rescale_q(packet->dts, inputStream.stream->time_base, AV_TIME_BASE_Q);
        int64_t delta   = pkt_dts - inputFile.lastTimestamp;
        if(delta < -1LL*dts_delta_threshold*AV_TIME_BASE ||
           (delta > 1LL*dts_delta_threshold*AV_TIME_BASE &&
            inputStream.stream->codec->codec_type != AVMEDIA_TYPE_SUBTITLE)){
               inputFile.timestampOffset -= delta;
               av_log(NULL, AV_LOG_DEBUG,
                      "Inter stream timestamp discontinuity %"PRId64", new offset= %"PRId64"\n",
                      delta, inputFile.timestampOffset);
               packet->dts -= av_rescale_q(delta, AV_TIME_BASE_Q, inputStream.stream->time_base);
               if (packet->pts != AV_NOPTS_VALUE)
                   packet->pts -= av_rescale_q(delta, AV_TIME_BASE_Q, inputStream.stream->time_base);
           }
    }
    
    if (packet->dts != AV_NOPTS_VALUE && inputStream.nextDTS != AV_NOPTS_VALUE &&
        !copy_ts) {
        int64_t pkt_dts = av_rescale_q(packet->dts, inputStream.stream->time_base, AV_TIME_BASE_Q);
        int64_t delta   = pkt_dts - inputStream.nextDTS;
        if (inputFormatContext->iformat->flags & AVFMT_TS_DISCONT) {
            if(delta < -1LL*dts_delta_threshold*AV_TIME_BASE ||
               (delta > 1LL*dts_delta_threshold*AV_TIME_BASE &&
                inputStream.stream->codec->codec_type != AVMEDIA_TYPE_SUBTITLE) ||
               pkt_dts+1<inputStream.PTS){
                inputFile.timestampOffset -= delta;
                av_log(NULL, AV_LOG_DEBUG,
                       "timestamp discontinuity %"PRId64", new offset= %"PRId64"\n",
                       delta, inputFile.timestampOffset);
                packet->dts -= av_rescale_q(delta, AV_TIME_BASE_Q, inputStream.stream->time_base);
                if (packet->pts != AV_NOPTS_VALUE)
                    packet->pts -= av_rescale_q(delta, AV_TIME_BASE_Q, inputStream.stream->time_base);
            }
        } else {
            if ( delta < -1LL*dts_error_threshold*AV_TIME_BASE ||
                (delta > 1LL*dts_error_threshold*AV_TIME_BASE && inputStream.stream->codec->codec_type != AVMEDIA_TYPE_SUBTITLE)
                ) {
                av_log(NULL, AV_LOG_WARNING, "DTS %"PRId64", next:%"PRId64" st:%d invalid dropping\n", packet->dts, inputStream.nextDTS, packet->stream_index);
                packet->dts = AV_NOPTS_VALUE;
            }
            if (packet->pts != AV_NOPTS_VALUE){
                int64_t pkt_pts = av_rescale_q(packet->pts, inputStream.stream->time_base, AV_TIME_BASE_Q);
                delta   = pkt_pts - inputStream.nextDTS;
                if ( delta < -1LL*dts_error_threshold*AV_TIME_BASE ||
                    (delta > 1LL*dts_error_threshold*AV_TIME_BASE && inputStream.stream->codec->codec_type != AVMEDIA_TYPE_SUBTITLE)
                    ) {
                    av_log(NULL, AV_LOG_WARNING, "PTS %"PRId64", next:%"PRId64" invalid dropping st:%d\n", packet->pts, inputStream.nextDTS, packet->stream_index);
                    packet->pts = AV_NOPTS_VALUE;
                }
            }
        }
    }
    
    if (packet->dts != AV_NOPTS_VALUE)
        inputFile.lastTimestamp = av_rescale_q(packet->dts, inputStream.stream->time_base, AV_TIME_BASE_Q);
    
    if (debug_ts) {
        av_log(NULL, AV_LOG_INFO, "demuxer+ffmpeg -> type:%s pkt_pts:%s pkt_pts_time:%s pkt_dts:%s pkt_dts_time:%s off:%s off_time:%s\n",
               av_get_media_type_string(inputStream.stream->codec->codec_type),
               av_ts2str(packet->pts), av_ts2timestr(packet->pts, &inputStream.stream->time_base),
               av_ts2str(packet->dts), av_ts2timestr(packet->dts, &inputStream.stream->time_base),
               av_ts2str(inputFile.timestampOffset),
               av_ts2timestr(inputFile.timestampOffset, &AV_TIME_BASE_Q));
    }
}


@end