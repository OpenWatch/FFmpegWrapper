//
//  FFOutputFile.h
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFFile.h"

#import "FFOutputStream.h"
#import "libavcodec/avcodec.h"
#import "FFBitstreamFilter.h"

@interface FFOutputFile : FFFile
@property (nonatomic) int64_t startTime;

// No need to call this function directly, streams are automatically added when created
- (void) addOutputStream:(FFOutputStream*)outputStream;


- (void) addBitstreamFilter:(FFBitstreamFilter*)bitstreamFilter;
- (void) removeBitstreamFilter:(FFBitstreamFilter*)bitstreamFilter;
- (NSSet*) bitstreamFilters;


// Must call this first
- (BOOL) openFileForWritingWithError:(NSError**)error;
// openFileForWritingWithError: must be called before calling this
- (BOOL) writeHeaderWithError:(NSError**)error;
// writeHeaderWithError: must be called before calling this
- (BOOL) writePacket:(AVPacket*)packet error:(NSError**)error;
// must call this when finished writing
- (BOOL) writeTrailerWithError:(NSError**)error;

@end