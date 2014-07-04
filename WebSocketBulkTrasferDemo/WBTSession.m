//
//  WVTSession.m
//  WebViewVideoTransfer_iOS
//
//  Created by Taiju Muto on 6/14/14.
//  Copyright (c) 2014 Taiju MUto. All rights reserved.
//

#import "WBTSession.h"
#include "sys/socket.h"

#define CHUNK_SIZE (128 * 1024)
#define USE_PERSISTENT_CONNECTION YES
#define SEND_BUFFER_SIZE (1024 * 1024)

//#define ENABLE_LOG

#ifdef ENABLE_LOG
#define DEBUG_LOG(...) NSLog(__VA_ARGS__)
#else
#define DEBUG_LOG(...)
#endif

@interface WBTSession ()<NSStreamDelegate>

@property (assign, nonatomic) CFSocketNativeHandle socket;
@property (retain, nonatomic) NSInputStream *inputStream;
@property (retain, nonatomic) NSOutputStream *outputStream;
@property (retain, nonatomic) NSMutableData *receiveBuffer;
@property (retain, nonatomic) NSMutableData *lineBuffer;
@property (assign, nonatomic) int linePos;
@property (retain, nonatomic) NSMutableArray *writeBuffers;
@property (assign, nonatomic) NSInteger writePos;
@property (assign, nonatomic) BOOL doClose;

@end

@implementation WBTSession

- (instancetype)initWithSocket:(CFSocketNativeHandle)socket
{
    CFReadStreamRef readStreamRef;
    CFWriteStreamRef writeStreamRef;
    CFStreamCreatePairWithSocket(NULL, socket, &readStreamRef, &writeStreamRef);
    if (!readStreamRef || !writeStreamRef) {
        return nil;
    }
    
    if (!CFReadStreamSetProperty(readStreamRef, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue) ||
        !CFWriteStreamSetProperty(writeStreamRef, kCFStreamPropertyShouldCloseNativeSocket, kCFBooleanTrue)) {
        CFRelease(readStreamRef);
        CFRelease(writeStreamRef);
        return nil;
    }
    
    NSInputStream *inputStream = (__bridge_transfer NSInputStream *)readStreamRef;
    NSOutputStream *outputStream = (__bridge_transfer NSOutputStream *)writeStreamRef;
    
    WBTSession *session = [super init];
    if (!session) {
        return nil;
    }
    
    int bufsize = SEND_BUFFER_SIZE;
    socklen_t size = sizeof(bufsize);
    if (setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &bufsize, size) == -1) {
        return nil;
    }
    
    session.socket = socket;
    session.receiveBuffer = [NSMutableData dataWithLength:RECV_BUFF_SIZE];
    session.lineBuffer = [NSMutableData dataWithLength:LINE_SIZE];
    session.linePos = 0;
    session.writePos = 0;
    session.writeBuffers = [NSMutableArray array];
    session.doClose = NO;
    
    session.inputStream = inputStream;
    session.inputStream.delegate = self;
    [session.inputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [session.inputStream open];
    
    session.outputStream = outputStream;
    session.outputStream.delegate = self;
    [session.outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [session.outputStream open];
    
    return session;
}

- (void)closeInput
{
    DEBUG_LOG(@"closeInput");
    
    if (self.inputStream) {
        [self.inputStream close];
        [self.inputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.inputStream = nil;
        
        if (!self.inputStream && !self.outputStream) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self];
            if (self.delegate) {
                [self.delegate didCloseSession:self];
            }
        }
    }
}

- (void)closeOutput
{
    DEBUG_LOG(@"closeOutput");
    
    if (self.outputStream) {
        [self.outputStream close];
        [self.outputStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        self.outputStream = nil;
        
        if (!self.inputStream && !self.outputStream) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self];
            if (self.delegate) {
                [self.delegate didCloseSession:self];
            }
        }
    }
}

- (void)close {
    [self closeInput];
    [self closeOutput];
}

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)streamEvent {
    if (streamEvent == NSStreamEventHasBytesAvailable) {
        DEBUG_LOG(@"NSStreamEventHasBytesAvailable");
        [self receive];
    } else if (streamEvent == NSStreamEventHasSpaceAvailable) {
        DEBUG_LOG(@"NSStreamEventHasSpaceAvailable");
        [self flush];
    } else if (streamEvent == NSStreamEventErrorOccurred) {
        DEBUG_LOG(@"NSStreamEventErrorOccurred");
        [self close];
    } else if (streamEvent == NSStreamEventEndEncountered) {
        DEBUG_LOG(@"NSStreamEventEndEncountered");
        if (stream == self.inputStream) {
            [self closeInput];
        } else if (stream == self.outputStream) {
            [self closeOutput];
        }
    }
}

- (void)receive
{
    while (self.inputStream.hasBytesAvailable) {
        NSInteger len = [self.inputStream read:self.receiveBuffer.mutableBytes maxLength:self.receiveBuffer.length];
        if (len > 0) {
            if (![self consume:len]) {
                [self close];
                break;
            }
        } else if (len < 0) {
            NSLog(@"read error. %@", self.inputStream.streamError.description);
            [self close];
            break;
        } else {
            break;
        }
    }
    [self flush];
}

- (BOOL)consume:(NSInteger)bytesReceived
{
    for (int i = 0; i < bytesReceived; i++) {
        char c = ((char *)self.receiveBuffer.bytes)[i];
        switch (c) {
            case '\r':
            {
                break;
            }
            case '\n':
            {
                if (0 < self.linePos) {
                    NSString *line = [[NSString alloc] initWithBytes:self.lineBuffer.bytes length:self.linePos encoding: NSASCIIStringEncoding];
                    [self dispatchLine:line];
                    self.linePos = 0;
                } else {
                    NSMutableData *body = [NSMutableData dataWithLength:CHUNK_SIZE];
                    [self sendResponse:body];
                }
                break;
            }
            default:
            {
                if (self.linePos < LINE_MAX) {
                    ((char *)self.lineBuffer.mutableBytes)[self.linePos++] = c;
                } else {
                    return NO;
                }
            }
        }
    }
    
    return YES;
}

- (void)dispatchLine:(NSString *)line
{
    DEBUG_LOG(@"%@", line);
}

- (void)flush
{
    DEBUG_LOG(@"flush");
    
    if (!self.outputStream) {
        return;
    }
        
    NSData *data;
    while (self.outputStream.hasSpaceAvailable && (data = self.writeBuffers.firstObject)) {
        NSInteger len = [self.outputStream write:data.bytes maxLength:data.length - self.writePos];
        if (len > 0) {
            self.writePos += len;
            if (self.writePos == data.length) {
                [self.writeBuffers removeObjectAtIndex:0];
                self.writePos = 0;
            } else {
                break;
            }
        } else if (len < 0) {
            NSLog(@"write error. %@", self.outputStream.streamError.description);
            [self close];
            break;
        } else {
            break;
        }
    }
    
    if (self.writeBuffers.count == 0 && self.doClose) {
        [self close];
    }
}

- (void)sendResponse:(NSData *)data
{
    DEBUG_LOG(@"sendResponse");
    
    NSMutableString *response = [NSMutableString string];
    
    [response appendString:@"HTTP/1.0 200 OK\r\n"];
    [response appendString:@"Connection: keep-alive\r\n"];
    [response appendFormat:@"Content-Length: %lu\r\n", (unsigned long)data.length];
    [response appendString:@"\r\n"];

    if (!USE_PERSISTENT_CONNECTION) {
        self.doClose = YES;
    }
    [self.writeBuffers addObject:[response dataUsingEncoding:NSASCIIStringEncoding]];
    [self.writeBuffers addObject:data];
}

@end
