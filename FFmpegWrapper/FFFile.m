//
//  FFFile.m
//  LiveStreamer
//
//  Created by Christopher Ballinger on 10/1/13.
//  Copyright (c) 2013 OpenWatch, Inc. All rights reserved.
//

#import "FFFile.h"

@implementation FFFile
@synthesize formatContext, streams;

- (id) initWithPath:(NSString *)newPath options:(NSDictionary *)newOptions {
    if (self = [super init]) {
        self.path = newPath;
        self.options = newOptions;
    }
    return self;
}

@end